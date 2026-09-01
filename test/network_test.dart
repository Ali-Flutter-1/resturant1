import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:practice/core/network/api_client.dart';
import 'package:practice/features/contact/data/api_contact_repository.dart';
import 'package:practice/features/orders/data/api_order_repository.dart';
import 'package:practice/features/orders/domain/customer_order.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/network/connectivity_service.dart';
import 'package:practice/core/network/token_store.dart';

/// Always reports a fixed state, so a test can be offline without an aeroplane.
class _FakeConnectivity extends ConnectivityService {
  _FakeConnectivity({required this.online});

  final bool online;

  @override
  Future<bool> get isOnline async => online;
}

/// Keeps tokens in memory. The real store talks to the platform keychain, which
/// does not exist in a widget test.
class _FakeTokens extends TokenStore {
  _FakeTokens({String? access, String? refresh})
    : _access = access,
      _refresh = refresh;

  String? _access;
  String? _refresh;

  @override
  Future<void> restore() async {}

  @override
  String? get accessToken => _access;

  @override
  String? get refreshToken => _refresh;

  @override
  Future<void> save({
    required String accessToken,
    required String refreshToken,
  }) async {
    _access = accessToken;
    _refresh = refreshToken;
  }

  @override
  Future<void> clear() async {
    _access = null;
    _refresh = null;
  }
}

/// Answers requests from a script, and records what it was asked.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final calls = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(int status, String body) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ApiClient _client({
  required Future<ResponseBody> Function(RequestOptions) handler,
  bool online = true,
  TokenStore? tokens,
  Future<void> Function()? onSessionExpired,
  _StubAdapter? adapter,
}) {
  final dio = Dio();
  dio.httpClientAdapter = adapter ?? _StubAdapter(handler);
  return ApiClient(
    tokens: tokens ?? _FakeTokens(),
    connectivity: _FakeConnectivity(online: online),
    dio: dio,
    onSessionExpired: onSessionExpired,
  );
}

void main() {
  setUpAll(() {
    // AppConfig reads `.env`, which is an asset and so is not present in a
    // plain Dart test. Feeding dotenv directly keeps the production code
    // honest — it still requires the variable rather than defaulting.
    dotenv.loadFromString(
      envString: 'API_BASE_URL=http://localhost:8000\nAPI_TIMEOUT_SECONDS=5',
    );
  });

  group('offline', () {
    test('fails before sending, with an honest message', () async {
      final adapter = _StubAdapter((_) async => _json(200, '{}'));
      final client = _client(
        handler: (_) async => _json(200, '{}'),
        online: false,
        adapter: adapter,
      );

      final failure = await client
          .object('/dishes')
          .then<ApiFailure?>(
            (_) => null,
            onError: (Object e) => e is ApiFailure ? e : null,
          );

      expect(failure, isNotNull);
      expect(failure!.kind, ApiFailureKind.offline);
      // The message must say nothing was sent — that is what stops a user
      // wondering whether their order went through.
      expect(failure.message, contains('offline'));
      expect(failure.message, contains('nothing has been sent'));
      expect(failure.isRetryable, isTrue);
      // Nothing left the device.
      expect(adapter.calls, isEmpty);
    });

    test(
      'a dropped connection is reported, not thrown as a raw error',
      () async {
        final client = _client(
          handler: (options) => throw DioException.connectionError(
            requestOptions: options,
            reason: 'closed',
            error: const SocketException('Network is unreachable'),
          ),
        );

        await expectLater(
          client.object('/dishes'),
          throwsA(
            isA<ApiFailure>()
                .having((f) => f.kind, 'kind', ApiFailureKind.unreachable)
                .having(
                  (f) => f.message,
                  'message',
                  contains("couldn't reach"),
                ),
          ),
        );
      },
    );
  });

  group('messages the user sees', () {
    test("the API's own message is preferred over any fallback", () async {
      final client = _client(
        handler: (_) async => _json(
          409,
          '{"success": false, "message": "That email is already registered.", '
          '"data": null}',
        ),
      );

      await expectLater(
        client.object('/auth/register', method: 'POST'),
        throwsA(
          isA<ApiFailure>()
              .having((f) => f.kind, 'kind', ApiFailureKind.conflict)
              .having(
                (f) => f.message,
                'message',
                'That email is already registered.',
              ),
        ),
      );
    });

    test('a bare 500 still reads as a sentence, never a status code', () async {
      final client = _client(
        handler: (_) async => _json(500, '{"success": false, "data": null}'),
      );

      final failure = await client
          .object('/dishes')
          .then<ApiFailure?>(
            (_) => null,
            onError: (Object e) => e is ApiFailure ? e : null,
          );

      expect(failure!.kind, ApiFailureKind.server);
      expect(failure.message, isNot(contains('500')));
      expect(failure.message, endsWith('.'));
    });

    test('FastAPI field errors are flattened for the form to use', () async {
      final client = _client(
        handler: (_) async => _json(
          422,
          '{"detail": [{"loc": ["body", "email"], '
          '"msg": "Enter a valid email address"}]}',
        ),
      );

      final failure = await client
          .object('/auth/register', method: 'POST')
          .then<ApiFailure?>(
            (_) => null,
            onError: (Object e) => e is ApiFailure ? e : null,
          );

      expect(failure!.kind, ApiFailureKind.invalid);
      expect(failure.fieldErrors['email'], 'Enter a valid email address');
      // The top-level message falls back to the field complaint rather than
      // showing the user an empty error.
      expect(failure.message, 'Enter a valid email address');
    });

    test('every failure kind has a readable fallback', () {
      for (final kind in ApiFailureKind.values) {
        final failure = ApiFailure.fromDio(
          DioException.badResponse(
            statusCode: switch (kind) {
              ApiFailureKind.unauthorised => 401,
              ApiFailureKind.notFound => 404,
              ApiFailureKind.conflict => 409,
              ApiFailureKind.invalid => 422,
              ApiFailureKind.tooManyRequests => 429,
              ApiFailureKind.server => 503,
              _ => 599,
            },
            requestOptions: RequestOptions(path: '/x'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/x'),
            ),
          ),
        );
        expect(failure.message, isNotEmpty);
        expect(
          failure.message,
          isNot(matches(RegExp(r'\b\d{3}\b'))),
          reason: 'a status code leaked into "${failure.message}"',
        );
      }
    });
  });

  group('session recovery', () {
    test('a 401 refreshes once and retries the original request', () async {
      final tokens = _FakeTokens(access: 'stale', refresh: 'good-refresh');
      var dishCalls = 0;

      late _StubAdapter adapter;
      adapter = _StubAdapter((options) async {
        if (options.path == '/auth/refresh') {
          return _json(
            200,
            '{"success": true, "message": "ok", "data": '
            '{"access_token": "fresh", "refresh_token": "next"}}',
          );
        }
        dishCalls++;
        // Unauthorised first, then accepted once the token is fresh.
        if (options.headers['Authorization'] == 'Bearer fresh') {
          return _json(200, '{"success": true, "message": "ok", "data": {}}');
        }
        return _json(401, '{"success": false, "message": "Expired."}');
      });

      final client = _client(
        handler: (_) async => _json(200, '{}'),
        tokens: tokens,
        adapter: adapter,
      );

      await client.object('/profile');

      expect(dishCalls, 2, reason: 'the original request should be retried');
      expect(tokens.accessToken, 'fresh');
      // The rotated refresh token must be stored: replaying the old one
      // revokes every session on this API.
      expect(tokens.refreshToken, 'next');
    });

    test('concurrent 401s refresh only once', () async {
      final tokens = _FakeTokens(access: 'stale', refresh: 'good-refresh');
      var refreshCalls = 0;

      final adapter = _StubAdapter((options) async {
        if (options.path == '/auth/refresh') {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return _json(
            200,
            '{"success": true, "message": "ok", "data": '
            '{"access_token": "fresh", "refresh_token": "next"}}',
          );
        }
        if (options.headers['Authorization'] == 'Bearer fresh') {
          return _json(200, '{"success": true, "message": "ok", "data": {}}');
        }
        return _json(401, '{"success": false, "message": "Expired."}');
      });

      final client = _client(
        handler: (_) async => _json(200, '{}'),
        tokens: tokens,
        adapter: adapter,
      );

      await Future.wait([
        client.object('/profile'),
        client.object('/orders'),
        client.object('/reservations'),
      ]);

      // Three simultaneous 401s, one refresh. Replaying a single-use refresh
      // token would sign the user out of everything.
      expect(refreshCalls, 1);
    });

    test('an unrecoverable session is reported once and cleared', () async {
      final tokens = _FakeTokens(access: 'stale', refresh: 'dead-refresh');
      var expiredCalls = 0;

      final adapter = _StubAdapter(
        (_) async => _json(401, '{"success": false, "message": "Expired."}'),
      );

      final client = _client(
        handler: (_) async => _json(200, '{}'),
        tokens: tokens,
        adapter: adapter,
        onSessionExpired: () async => expiredCalls++,
      );

      await expectLater(
        client.object('/profile'),
        throwsA(
          isA<ApiFailure>().having((f) => f.requiresSignIn, 'signIn', isTrue),
        ),
      );

      expect(expiredCalls, 1);
      expect(
        tokens.refreshToken,
        isNull,
        reason: 'a dead token must not linger',
      );
    });
  });

  group('envelope', () {
    test('unwraps data, and items for paginated endpoints', () async {
      final client = _client(
        handler: (options) async => options.path == '/dishes'
            ? _json(
                200,
                '{"success": true, "message": "ok", "data": '
                '[{"id": "1"}, {"id": "2"}]}',
              )
            : _json(
                200,
                '{"success": true, "message": "ok", "data": '
                '{"items": [{"id": "9"}], "page": 1}}',
              ),
      );

      expect(await client.list('/dishes'), hasLength(2));
      expect((await client.list('/orders')).single['id'], '9');
    });
  });

  group('the API error envelope', () {
    // Captured from the live API rather than imagined. The shape is
    // `{success, message, error: {code, details: [{field, message}]}}`.
    ApiFailure failureFor(int status, String body) {
      final response = Response<dynamic>(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: status,
        data: jsonDecode(body),
      );
      return ApiFailure.fromDio(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.badResponse,
        ),
      );
    }

    test('reads per-field messages from error.details', () {
      final failure = failureFor(
        422,
        '{"success": false, '
        '"message": "Please check the highlighted fields and try again.", '
        '"error": {"code": "VALIDATION_FAILED", "details": ['
        '{"field": "email", "message": "Enter a valid email address."},'
        '{"field": "password", "message": "Password is required."}]}}',
      );

      // The app used to read only FastAPI's raw `detail: [{loc, msg}]`, which
      // this backend never sends — so every field error was dropped and a
      // rejected form showed one sentence at the top with no indication of
      // which box was wrong.
      expect(failure.fieldErrors, {
        'email': 'Enter a valid email address.',
        'password': 'Password is required.',
      });
      expect(
        failure.message,
        'Please check the highlighted fields and try again.',
      );
      expect(failure.code, 'VALIDATION_FAILED');
    });

    test("still understands FastAPI's own shape", () {
      final failure = failureFor(
        422,
        '{"detail": [{"loc": ["body", "email"], "msg": "field required"}]}',
      );

      // Anything not wrapped by the app envelope — a framework-level refusal —
      // must still mark the field.
      expect(failure.fieldErrors, {'email': 'field required'});
    });

    test('401 is a session problem', () {
      final failure = failureFor(
        401,
        '{"success": false, "message": "You need to sign in to continue.", '
        '"error": {"code": "MISSING_ACCESS_TOKEN", "details": []}}',
      );

      expect(failure.kind, ApiFailureKind.unauthorised);
      expect(failure.requiresSignIn, isTrue);
      expect(failure.code, 'MISSING_ACCESS_TOKEN');
    });

    test('403 is a role problem, and must not send anyone to sign in', () {
      final failure = failureFor(
        403,
        '{"success": false, "message": "You do not have access to this.", '
        '"error": {"code": "PERMISSION_DENIED", "details": []}}',
      );

      // Both used to be `unauthorised`, so a customer touching an admin route
      // was told their session had expired — and signing in again produces the
      // same role and the same refusal.
      expect(failure.kind, ApiFailureKind.forbidden);
      expect(failure.requiresSignIn, isFalse);
      expect(failure.isRetryable, isFalse);
    });

    test('a 409 carries the code the app can branch on', () {
      final failure = failureFor(
        409,
        '{"success": false, "message": "The kitchen has already started this '
        'order. Please call us.", '
        '"error": {"code": "ORDER_TOO_LATE_TO_CANCEL", "details": []}}',
      );

      expect(failure.kind, ApiFailureKind.conflict);
      expect(failure.code, 'ORDER_TOO_LATE_TO_CANCEL');
      // The API's wording reaches the user unchanged; nothing is invented.
      expect(failure.message, contains('Please call us'));
    });

    test('an envelope with no message falls back to plain English', () {
      final failure = failureFor(500, '{"success": false}');

      expect(failure.code, isNull);
      expect(failure.message, isNot(contains('500')));
      expect(failure.isRetryable, isTrue);
    });
  });

  group('cancelling an order on the wire', () {
    Future<ResponseBody> ok(RequestOptions _) async => _json(
      200,
      '{"success":true,"message":"Your order has been cancelled.",'
      '"data":{"id":"o1","status":"cancelled",'
      '"cancellation_reason":"Ordered by mistake"}}',
    );

    test('sends a JSON body even when there is no reason', () async {
      final adapter = _StubAdapter(ok);
      final repository = ApiOrderRepository(
        client: _client(handler: ok, adapter: adapter),
      );

      await repository.cancel('o1');

      // The route declares a required body. Sending none at all -- which is
      // what a bare POST does -- comes back as a validation error rather than
      // a cancellation, so the key goes out even when it is null.
      final call = adapter.calls.single;
      expect(call.method, 'POST');
      expect(call.path, contains('/orders/o1/cancel'));
      expect(call.data, isA<Map<String, dynamic>>());
    });

    test("sends the customer's reason, trimmed", () async {
      final adapter = _StubAdapter(ok);
      final repository = ApiOrderRepository(
        client: _client(handler: ok, adapter: adapter),
      );

      await repository.cancel('o1', reason: '  Ordered by mistake  ');

      expect(
        (adapter.calls.single.data as Map)['reason'],
        'Ordered by mistake',
      );
    });

    test('truncates a reason past the 500 the API accepts', () async {
      final adapter = _StubAdapter(ok);
      final repository = ApiOrderRepository(
        client: _client(handler: ok, adapter: adapter),
      );

      await repository.cancel('o1', reason: 'x' * 600);

      // Truncated rather than refused: losing the tail of a long explanation
      // is better than refusing to cancel the order over it.
      expect((adapter.calls.single.data as Map)['reason'], hasLength(500));
    });
  });

  group('placing a card order on the wire', () {
    Future<ResponseBody> ok(RequestOptions _) async => _json(
      201,
      '{"success":true,"message":"Order placed.","data":{"id":"o1",'
      '"payment_method":"card","payment_status":"pending",'
      '"payment_url":"https://hpp-sandbox.worldpay.com/x"}}',
    );

    test('sends payment_method card, and never a price', () async {
      final adapter = _StubAdapter(ok);
      final repository = ApiOrderRepository(
        client: _client(handler: ok, adapter: adapter),
      );

      final order = await repository.place(
        idempotencyKey: 'key-1',
        isDelivery: false,
        lines: const [],
        contactName: 'Ali',
        contactPhone: '07700 900123',
        paymentMethod: PaymentMethod.card,
      );

      final body = adapter.calls.single.data as Map;
      expect(body['payment_method'], 'card');
      // The server prices the basket and tells Worldpay the total; an amount
      // from the app would be forgeable.
      expect(body.keys, isNot(contains('total_pence')));
      expect(order.paymentUrl, isNotNull);
    });

    test('reads the page back off the placement response', () async {
      final repository = ApiOrderRepository(client: _client(handler: ok));
      final order = await repository.place(
        idempotencyKey: 'key-1',
        isDelivery: false,
        lines: const [],
        contactName: 'Ali',
        contactPhone: '07700 900123',
        paymentMethod: PaymentMethod.card,
      );

      expect(order.isCard, isTrue);
      expect(order.needsPayment, isTrue);
      expect(order.paymentUrl, 'https://hpp-sandbox.worldpay.com/x');
    });
  });

  group('quoting on the wire', () {
    Future<ResponseBody> ok(RequestOptions _) async => _json(
      200,
      '{"success":true,"message":"ok","data":{"items":[],'
      '"subtotal_pence":0,"delivery_fee_pence":400,"total_pence":400,'
      '"minimum_order_pence":3000,"meets_minimum":false,'
      '"earliest_slot":null,"available_slots":[]}}',
    );

    test('a delivery quote carries the postcode, normalised', () async {
      final adapter = _StubAdapter(ok);
      final repository = ApiOrderRepository(
        client: _client(handler: ok, adapter: adapter),
      );

      await repository.quote(
        isDelivery: true,
        lines: const [],
        postcode: ' kw14 7el ',
      );

      // The zone -- and so the fee and the minimum -- is decided by this.
      final body = adapter.calls.single.data as Map;
      expect(body['postcode'], 'KW14 7EL');
    });

    test('a collection quote sends no postcode at all', () async {
      final adapter = _StubAdapter(ok);
      final repository = ApiOrderRepository(
        client: _client(handler: ok, adapter: adapter),
      );

      await repository.quote(
        isDelivery: false,
        lines: const [],
        postcode: 'KW14 7EL',
      );

      // Ignored by the server, but sending it would imply the address matters
      // to a collection order, and an empty string would fail the lookup
      // rather than being read as absent.
      expect(
        (adapter.calls.single.data as Map).keys,
        isNot(contains('postcode')),
      );
    });

    test('an empty postcode is left out rather than sent blank', () async {
      final adapter = _StubAdapter(ok);
      final repository = ApiOrderRepository(
        client: _client(handler: ok, adapter: adapter),
      );

      await repository.quote(isDelivery: true, lines: const [], postcode: '  ');

      expect(
        (adapter.calls.single.data as Map).keys,
        isNot(contains('postcode')),
      );
    });
  });

  group('the contact form on the wire', () {
    Future<ResponseBody> ok(RequestOptions _) async =>
        _json(200, '{"success":true,"message":"Thanks.","data":null}');

    ApiContactRepository contactWith(_StubAdapter adapter) =>
        ApiContactRepository(
          client: _client(handler: ok, adapter: adapter),
        );

    test('normalises the email and trims everything', () async {
      final adapter = _StubAdapter(ok);

      await contactWith(adapter).send(
        name: '  Ali Hassan ',
        email: '  Ali@Example.COM ',
        message: '  Do you cater? ',
      );

      final body = adapter.calls.single.data as Map;
      // The address is an identifier as far as the restaurant is concerned, so
      // it is stored one way rather than however it was typed.
      expect(body['email'], 'ali@example.com');
      expect(body['name'], 'Ali Hassan');
      expect(body['message'], 'Do you cater?');
    });

    test('blank optional fields are omitted, not sent empty', () async {
      final adapter = _StubAdapter(ok);

      await contactWith(adapter).send(
        name: 'Ali',
        email: 'ali@example.com',
        message: 'Hello',
        phone: '   ',
        subject: '',
      );

      // An empty string is a value: the API would store a subject of "" and
      // the admin inbox would show a message headed by nothing at all.
      final body = adapter.calls.single.data as Map;
      expect(body.keys, isNot(contains('phone')));
      expect(body.keys, isNot(contains('subject')));
    });

    test('optional fields are sent when given', () async {
      final adapter = _StubAdapter(ok);

      await contactWith(adapter).send(
        name: 'Ali',
        email: 'ali@example.com',
        message: 'Hello',
        phone: ' 07700 900123 ',
        subject: ' Catering ',
      );

      final body = adapter.calls.single.data as Map;
      expect(body['phone'], '07700 900123');
      expect(body['subject'], 'Catering');
    });

    test('a null data payload is a success, not a parse failure', () async {
      // The route answers `{success, message, data: null}`. Asking for an
      // object would throw on the null even though the message arrived, and
      // the customer would be told their message failed after it was sent.
      await expectLater(
        contactWith(
          _StubAdapter(ok),
        ).send(name: 'Ali', email: 'ali@example.com', message: 'Hello'),
        completes,
      );
    });

    test(
      'needs no session: it is who cannot sign in that most needs it',
      () async {
        final adapter = _StubAdapter(ok);
        await contactWith(
          adapter,
        ).send(name: 'Ali', email: 'ali@example.com', message: 'Hello');

        // No tokens in this client, and the call still goes through.
        expect(adapter.calls.single.headers, isNot(contains('Authorization')));
      },
    );
  });
}
