import 'package:dio/dio.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:practice/core/network/api_client.dart';
import 'package:practice/core/network/api_failure.dart';
import 'package:practice/core/network/connectivity_service.dart';
import 'package:practice/core/network/token_store.dart';
import 'package:practice/features/auth/data/api_auth_repository.dart';
import 'package:practice/features/auth/domain/auth_user.dart';

class _AlwaysOnline extends ConnectivityService {
  @override
  Future<bool> get isOnline async => true;
}

class _MemoryTokens extends TokenStore {
  String? access;
  String? refresh;
  int clearCalls = 0;

  @override
  Future<void> restore() async {}

  @override
  String? get accessToken => access;

  @override
  String? get refreshToken => refresh;

  @override
  Future<void> save({
    required String accessToken,
    required String refreshToken,
  }) async {
    access = accessToken;
    refresh = refreshToken;
  }

  @override
  Future<void> clear() async {
    clearCalls++;
    access = null;
    refresh = null;
  }
}

class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;
  final bodies = <String, Object?>{};

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) {
    bodies[options.path] = options.data;
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

void main() {
  setUpAll(() {
    dotenv.loadFromString(
      envString: 'API_BASE_URL=http://localhost:8000\nAPI_TIMEOUT_SECONDS=5',
    );
  });

  ({ApiAuthRepository repo, _MemoryTokens tokens, _StubAdapter adapter}) build(
    Future<ResponseBody> Function(RequestOptions) handler, {
    _MemoryTokens? tokens,
  }) {
    final store = tokens ?? _MemoryTokens();
    final adapter = _StubAdapter(handler);
    final dio = Dio()..httpClientAdapter = adapter;
    final client = ApiClient(
      tokens: store,
      connectivity: _AlwaysOnline(),
      dio: dio,
    );
    return (
      repo: ApiAuthRepository(client: client, tokens: store),
      tokens: store,
      adapter: adapter,
    );
  }

  test('login normalises the email and stores the token pair', () async {
    final built = build(
      (_) async => _json(
        200,
        '{"success": true, "message": "Signed in", "data": {'
        '"user": {"id": "1", "email": "boss@tscafe.co.uk", '
        '"first_name": "Sam", "last_name": "Owner", "role": "admin"}, '
        '"tokens": {"access_token": "a1", "refresh_token": "r1"}}}',
      ),
    );

    final user = await built.repo.login(
      email: '  Boss@TsCafe.co.uk ',
      password: 'secret',
    );

    expect(user.role, UserRole.admin);
    // Trimmed and lower-cased, so a stray capital or a pasted space isn't
    // reported back as "no account for that email".
    final sent = built.adapter.bodies['/auth/login'] as Map;
    expect(sent['email'], 'boss@tscafe.co.uk');
    expect(sent['password'], 'secret');
    // Tokens are persisted here and nowhere else.
    expect(built.tokens.access, 'a1');
    expect(built.tokens.refresh, 'r1');
  });

  test('a token-only sign-in falls back to asking who we are', () async {
    var meCalls = 0;
    final built = build((options) async {
      if (options.path == '/auth/me') {
        meCalls++;
        return _json(
          200,
          '{"success": true, "message": "ok", "data": {"id": "1", '
          '"email": "a@b.com", "first_name": "A", "last_name": "B", '
          '"role": "staff"}}',
        );
      }
      return _json(
        200,
        '{"success": true, "message": "ok", "data": {"tokens": '
        '{"access_token": "a1", "refresh_token": "r1"}}}',
      );
    });

    final user = await built.repo.login(email: 'a@b.com', password: 'x');

    // The role decides which half of the app opens, so guessing is not an
    // option — it asks.
    expect(meCalls, 1);
    expect(user.role, UserRole.staff);
  });

  test('signing out forgets the session before any request', () async {
    final tokens = _MemoryTokens()
      ..access = 'a1'
      ..refresh = 'r1';
    final built = build(
      (_) async => _json(500, '{"success": false, "message": "Boom"}'),
      tokens: tokens,
    );

    // The device forgets first and revokes second. Clearing after the round
    // trip left a window -- as long as the timeout on a bad connection -- in
    // which restarting the app signed the same person straight back in, and a
    // fresh sign-in had its tokens wiped by the old logout finishing.
    final revoked = await built.repo.forgetSession();
    expect(revoked, 'r1');
    expect(tokens.refresh, isNull);
    expect(tokens.clearCalls, 1);

    // And the revoke itself must not throw: the user asked to sign out, and a
    // server problem cannot be allowed to leave them apparently signed in.
    await built.repo.logout(refreshToken: revoked);
  });

  test('changing the password adopts the new token pair', () async {
    final tokens = _MemoryTokens()
      ..access = 'old'
      ..refresh = 'old-r';
    final built = build(
      (_) async => _json(
        200,
        '{"success": true, "message": "Changed", "data": '
        '{"access_token": "new", "refresh_token": "new-r"}}',
      ),
      tokens: tokens,
    );

    await built.repo.changePassword(currentPassword: 'old', newPassword: 'new');

    // The server revoked the old sessions, so failing to store these would
    // sign this device out a moment later.
    expect(tokens.access, 'new');
    expect(tokens.refresh, 'new-r');
  });

  test('a refused sign-in arrives as a readable ApiFailure', () async {
    final built = build(
      (_) async => _json(
        401,
        '{"success": false, "message": "That email and password do not match."}',
      ),
    );

    await expectLater(
      built.repo.login(email: 'a@b.com', password: 'no'),
      throwsA(
        isA<ApiFailure>().having(
          (f) => f.message,
          'message',
          'That email and password do not match.',
        ),
      ),
    );
  });

  group('routes that answer with no data', () {
    // `{"success": true, "message": "…", "data": null}` is a *success*. These
    // used to go through `object()`, which demands a Map and threw "The server
    // sent something unexpected" on the null — so forgot-password reported a
    // failure on every request that actually worked, and the email had already
    // been sent.
    const nullData =
        '{"success": true, "message": "If that address has an account, '
        'a reset link is on its way.", "data": null}';

    test('forgot-password succeeds on a null-data envelope', () async {
      final built = build((_) async => _json(200, nullData));

      await expectLater(
        built.repo.requestPasswordReset('  Boss@TsCafe.co.uk '),
        completes,
      );

      final sent = built.adapter.bodies['/auth/forgot-password'] as Map;
      // Normalised like sign-in, so a pasted space or a stray capital does not
      // quietly fail to match the account.
      expect(sent['email'], 'boss@tscafe.co.uk');
    });

    test('reset-password succeeds and sends the documented body', () async {
      final built = build((_) async => _json(200, nullData));

      await expectLater(
        built.repo.resetPassword(token: '  tok-123 ', newPassword: 'newpass1'),
        completes,
      );

      final sent = built.adapter.bodies['/auth/reset-password'] as Map;
      expect(sent['token'], 'tok-123');
      expect(sent['new_password'], 'newpass1');
    });

    test('logout revokes the token it was handed', () async {
      final tokens = _MemoryTokens()
        ..access = 'a1'
        ..refresh = 'r1';
      final built = build((_) async => _json(200, nullData), tokens: tokens);

      final revoked = await built.repo.forgetSession();
      await built.repo.logout(refreshToken: revoked);

      // The store is already empty by now, so the token has to travel with the
      // call rather than be read back out of it.
      final sent = built.adapter.bodies['/auth/logout'] as Map;
      expect(sent['refresh_token'], 'r1');
      expect(built.tokens.refresh, isNull);
    });

    test('nothing to revoke means no request at all', () async {
      final built = build((_) async => _json(200, nullData));

      await built.repo.logout();

      // A session that was never there, or one already forgotten: posting a
      // null token would be a guaranteed 422.
      expect(built.adapter.bodies.containsKey('/auth/logout'), isFalse);
    });

    test('a real forgot-password failure still surfaces', () async {
      final built = build(
        (_) async => _json(
          429,
          '{"success": false, "message": "Too many requests. Try again in a '
          'minute.", "data": null}',
        ),
      );

      // The fix must not turn every response into a success.
      await expectLater(
        built.repo.requestPasswordReset('boss@tscafe.co.uk'),
        throwsA(
          isA<ApiFailure>().having(
            (f) => f.message,
            'message',
            'Too many requests. Try again in a minute.',
          ),
        ),
      );
    });
  });

  group('the cached profile', () {
    test('is written from /auth/me and read back as a user', () async {
      final built = build(
        (_) async => _json(
          200,
          '{"success":true,"message":"ok","data":{"id":"u1",'
          '"email":"ali@example.com","first_name":"Ali","last_name":"Hassan",'
          '"role":"admin"}}',
        ),
      );

      await built.repo.currentUser();

      // The role is the part that matters: it decides which half of the app
      // opens when there is no network to ask.
      expect(built.tokens.lastUser, isNotNull);
      expect(built.repo.cachedUser?.role, UserRole.admin);
      expect(built.repo.cachedUser?.email, 'ali@example.com');
    });

    test('is written on sign-in too, not only on restore', () async {
      final built = build(
        (_) async => _json(
          200,
          '{"success": true, "message": "Signed in", "data": {'
          '"user": {"id": "1", "email": "boss@tscafe.co.uk", '
          '"first_name": "Sam", "last_name": "Owner", "role": "staff"}, '
          '"tokens": {"access_token": "a1", "refresh_token": "r1"}}}',
        ),
      );

      await built.repo.login(email: 'boss@tscafe.co.uk', password: 'secret');

      // Otherwise the first launch after signing in -- the one most likely to
      // be on a patchy connection -- would have a token and no idea whose.
      expect(built.repo.cachedUser?.role, UserRole.staff);
    });

    test('never stores what the API says to keep out of the app', () async {
      final built = build(
        (_) async => _json(
          200,
          '{"success":true,"message":"ok","data":{"id":"u1",'
          '"email":"ali@example.com","first_name":"Ali","last_name":"Hassan",'
          '"role":"customer","password_hash":"secret-hash-value",'
          '"google_sub":"110169484474386276334"}}',
        ),
      );

      await built.repo.currentUser();

      // Written from the model rather than the response, so a server that
      // starts sending these cannot leak them onto the device.
      final stored = built.tokens.lastUser!;
      expect(stored, isNot(contains('password_hash')));
      expect(stored, isNot(contains('secret-hash-value')));
      expect(stored, isNot(contains('google_sub')));
    });

    test('a corrupt cache reads as no cache, not as a crash', () async {
      final built = build((_) async => _json(200, '{}'));
      await built.tokens.saveUser('{not json at all');

      // A cache written by an older build must not take startup down.
      expect(built.repo.cachedUser, isNull);
    });
  });
}
