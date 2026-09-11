import 'dart:async';

import 'package:dio/dio.dart';

import '../config/app_config.dart';
import 'api_constants.dart';
import 'api_failure.dart';
import 'page_data.dart';
import 'connectivity_service.dart';
import 'token_store.dart';

/// The single door to the API.
///
/// Everything a repository needs and nothing it doesn't: the envelope is
/// unwrapped here, tokens are attached here, expiry is recovered from here, and
/// every error leaves as an [ApiFailure] with a message fit to show a person.
/// No repository sees a `DioException`, a status code, or a raw envelope.
class ApiClient {
  ApiClient({
    required TokenStore tokens,
    required ConnectivityService connectivity,
    Dio? dio,
    this.onSessionExpired,
  }) : _tokens = tokens,
       _connectivity = connectivity,
       _dio = dio ?? Dio() {
    _dio.options = _dio.options.copyWith(
      baseUrl: ApiConstants.apiRoot,
      connectTimeout: AppConfig.apiTimeout,
      sendTimeout: AppConfig.apiTimeout,
      receiveTimeout: AppConfig.apiTimeout,
      contentType: Headers.jsonContentType,
      // Dio's default: non-2xx throws. That is load-bearing, not incidental —
      // the 401 handler below is an `onError` interceptor, so suppressing the
      // exception would silently disable token refresh entirely.
    );

    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _attachToken, onError: _recoverOrFail),
    );
  }

  /// Requests that must not carry a token, and must never trigger a refresh.
  static const _publicPaths = {
    ApiConstants.register,
    ApiConstants.login,
    ApiConstants.refresh,
    ApiConstants.logout,
    ApiConstants.google,
    ApiConstants.forgotPassword,
    ApiConstants.resetPassword,
  };

  final Dio _dio;
  final TokenStore _tokens;
  final ConnectivityService _connectivity;

  /// Called once the session is unrecoverable, so the app can return to
  /// sign-in rather than leaving the user on a screen that will never load.
  ///
  /// Settable because the client and the session cubit each need the other: the
  /// cubit's repository needs a client, and the client needs somewhere to
  /// report expiry. Assigning after construction breaks that cycle without a
  /// locator or a lazy indirection.
  Future<void> Function()? onSessionExpired;

  /// The refresh currently in flight, if any.
  ///
  /// This is the whole reason refresh is centralised. This API rotates refresh
  /// tokens on use and revokes *every* session if one is replayed — so two
  /// requests 401-ing at the same moment must not each try to refresh. The
  /// second awaits the first instead.
  Future<bool>? _refreshing;

  void _attachToken(RequestOptions options, RequestInterceptorHandler handler) {
    final token = _tokens.accessToken;
    final isPublic = _publicPaths.contains(options.path);
    if (token != null && !isPublic) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  Future<void> _recoverOrFail(
    DioException error,
    ErrorInterceptorHandler handler,
  ) async {
    final path = error.requestOptions.path;
    final isRetry = error.requestOptions.extra['__retried'] == true;

    final shouldRefresh =
        error.response?.statusCode == 401 &&
        !isRetry &&
        !_publicPaths.contains(path) &&
        _tokens.refreshToken != null;

    if (!shouldRefresh) {
      handler.next(error);
      return;
    }

    final refreshed = await _refreshOnce();
    if (!refreshed) {
      await _tokens.clear();
      await onSessionExpired?.call();
      handler.next(error);
      return;
    }

    try {
      final options = error.requestOptions;
      options.extra['__retried'] = true;
      final retried = await _dio.fetch<dynamic>(options);
      handler.resolve(retried);
    } on DioException catch (retryError) {
      handler.next(retryError);
    }
  }

  /// Refreshes at most once at a time; concurrent callers share the result.
  Future<bool> _refreshOnce() {
    return _refreshing ??= _performRefresh().whenComplete(() {
      _refreshing = null;
    });
  }

  Future<bool> _performRefresh() async {
    final token = _tokens.refreshToken;
    if (token == null) return false;
    try {
      final response = await _dio.post<dynamic>(
        ApiConstants.refresh,
        data: {'refresh_token': token},
        // A failed refresh is an expected outcome, not an exception: it means
        // the session is over, which the caller handles.
        options: Options(validateStatus: (_) => true),
      );
      if (response.statusCode != 200) return false;
      final data = _dataOf(response.data);
      if (data is! Map) return false;
      final access = data['access_token'];
      final refresh = data['refresh_token'];
      if (access is! String || refresh is! String) return false;
      await _tokens.save(accessToken: access, refreshToken: refresh);
      return true;
    } on Object {
      return false;
    }
  }

  static Object? _dataOf(Object? body) =>
      body is Map && body.containsKey('data') ? body['data'] : body;

  /// Sends a request and returns the envelope's `data`, or throws [ApiFailure].
  ///
  /// Connectivity is checked first so an offline attempt fails immediately with
  /// an honest message instead of waiting out the timeout.
  Future<Object?> send(
    String path, {
    String method = 'GET',
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) async {
    if (!await _connectivity.isOnline) throw ApiFailure.offline;

    try {
      final response = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method, headers: headers),
      );
      return _dataOf(response.data);
    } on DioException catch (error) {
      // The single place a response becomes a message. Offline was already
      // raised above, so anything here is a real transport or protocol
      // failure — including a 401 that refresh could not recover.
      throw ApiFailure.fromDio(error);
    }
  }

  /// Uploads files as `multipart/form-data` and returns the envelope's `data`.
  ///
  /// Kept alongside [send] rather than folded into it: a multipart body is not a
  /// JSON body, and giving [send] a second body type would mean every caller
  /// reads a branch that only one of them uses. Everything else — the
  /// connectivity pre-flight, the auth header, the 401 refresh, the failure
  /// translation — is shared, because it all lives in the interceptors and the
  /// catch below rather than in [send].
  Future<Object?> upload(
    String path, {
    required String field,
    required List<String> filePaths,
    Map<String, dynamic>? query,
  }) async {
    if (!await _connectivity.isOnline) throw ApiFailure.offline;

    try {
      final form = FormData();
      for (final filePath in filePaths) {
        // Repeated entries under one field name, which is how a list of files is
        // sent — `MapEntry`s rather than a map, because a map could only hold
        // one.
        form.files.add(MapEntry(field, await MultipartFile.fromFile(filePath)));
      }

      final response = await _dio.post<dynamic>(
        path,
        data: form,
        queryParameters: query,
      );
      return _dataOf(response.data);
    } on DioException catch (error) {
      throw ApiFailure.fromDio(error);
    } on ApiFailure {
      rethrow;
    } on Object catch (_) {
      // A file that vanished between being picked and being read, most often.
      // Reported like any other failure so the caller has one thing to catch.
      throw const ApiFailure(
        kind: ApiFailureKind.unknown,
        message: 'That image could not be read. Try choosing it again.',
      );
    }
  }

  /// [upload] for endpoints returning a JSON array.
  Future<List<Map<String, dynamic>>> uploadList(
    String path, {
    required String field,
    required List<String> filePaths,
  }) async {
    final data = await upload(path, field: field, filePaths: filePaths);
    final rows = data is Map && data['items'] is List ? data['items'] : data;
    if (rows is! List) {
      throw const ApiFailure(
        kind: ApiFailureKind.unknown,
        message: 'The server sent something unexpected. Please try again.',
      );
    }
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  /// [send] for endpoints returning a JSON object.
  Future<Map<String, dynamic>> object(
    String path, {
    String method = 'GET',
    Object? body,
    Map<String, dynamic>? query,
    Map<String, String>? headers,
  }) async {
    final data = await send(
      path,
      method: method,
      body: body,
      query: query,
      headers: headers,
    );
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return Map<String, dynamic>.from(data);
    throw const ApiFailure(
      kind: ApiFailureKind.unknown,
      message: 'The server sent something unexpected. Please try again.',
    );
  }

  /// [send] for a paginated endpoint, keeping the counts.
  ///
  /// The `{items, page, page_size, total, total_pages}` envelope, decoded whole —
  /// [list] drops everything but the rows, which is enough until a screen needs
  /// to know whether there is another page.
  Future<PageData<Map<String, dynamic>>> page(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final data = await send(path, query: query);
    if (data is! Map) {
      throw const ApiFailure(
        kind: ApiFailureKind.unknown,
        message: 'The server sent something unexpected. Please try again.',
      );
    }

    final rows = data['items'];
    return PageData(
      items: rows is List
          ? rows
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .toList()
          : const [],
      page: (data['page'] as num?)?.toInt() ?? 1,
      pageSize: (data['page_size'] as num?)?.toInt() ?? 20,
      total: (data['total'] as num?)?.toInt() ?? 0,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
    );
  }

  /// [page], for an endpoint that may or may not be paginated.
  ///
  /// Some list routes wrap their rows in the `{items, page, total_pages}`
  /// envelope and some return a bare array, and which is which is not
  /// something a screen should have to know -- nor something that should
  /// break if the backend starts paginating a route that did not before.
  ///
  /// A bare array comes back as a single complete page, so `hasMore` is false
  /// and nothing offers to fetch a second one that does not exist.
  Future<PageData<Map<String, dynamic>>> maybePage(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final data = await send(path, query: query);

    if (data is List) {
      final rows = data
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
      return PageData(
        items: rows,
        page: 1,
        pageSize: rows.length,
        total: rows.length,
        // One page when there is anything, none when there is not -- so an
        // empty result never invites a request for page one of nothing.
        totalPages: rows.isEmpty ? 0 : 1,
      );
    }

    if (data is! Map) {
      throw const ApiFailure(
        kind: ApiFailureKind.unknown,
        message: 'The server sent something unexpected. Please try again.',
      );
    }

    final rows = data['items'];
    return PageData(
      items: rows is List
          ? rows
                .whereType<Map>()
                .map((row) => Map<String, dynamic>.from(row))
                .toList()
          : const [],
      page: (data['page'] as num?)?.toInt() ?? 1,
      pageSize: (data['page_size'] as num?)?.toInt() ?? 20,
      total: (data['total'] as num?)?.toInt() ?? 0,
      totalPages: (data['total_pages'] as num?)?.toInt() ?? 0,
    );
  }

  /// [send] for endpoints returning a JSON array.
  Future<List<Map<String, dynamic>>> list(
    String path, {
    String method = 'GET',
    Object? body,
    Map<String, dynamic>? query,
  }) async {
    final data = await send(path, method: method, body: body, query: query);
    // Paginated endpoints wrap the rows in `items`; plain ones return a bare
    // array. Callers shouldn't have to care which.
    final rows = data is Map && data['items'] is List ? data['items'] : data;
    if (rows is! List) {
      throw const ApiFailure(
        kind: ApiFailureKind.unknown,
        message: 'The server sent something unexpected. Please try again.',
      );
    }
    return rows
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }
}
