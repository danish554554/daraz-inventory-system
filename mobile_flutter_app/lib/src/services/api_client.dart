import 'dart:async';
import 'dart:convert';


import 'package:http/http.dart' as http;

import 'api_exception.dart';
import 'app_config.dart';
import 'session_manager.dart';

class _CachedApiResponse {
  _CachedApiResponse(this.value, this.createdAt);

  final dynamic value;
  final DateTime createdAt;
}

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  final http.Client _httpClient = http.Client();
  final Map<String, _CachedApiResponse> _memoryCache = <String, _CachedApiResponse>{};
  final Map<String, Future<dynamic>> _inFlightGets = <String, Future<dynamic>>{};
  static const Duration _defaultCacheTtl = Duration(seconds: 30);
  static const Duration _defaultTimeout = Duration(seconds: 45);

  Future<dynamic> get(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = true,
    bool bypassCache = false,
    Duration? timeout,
  }) {
    return _send(
      method: 'GET',
      path: path,
      queryParameters: queryParameters,
      requiresAuth: requiresAuth,
      bypassCache: bypassCache,
      timeout: timeout,
    );
  }

  void clearCache() {
    _memoryCache.clear();
    _inFlightGets.clear();
  }

  Future<dynamic> post(
    String path, {
    Map<String, dynamic>? queryParameters,
    Object? body,
    bool requiresAuth = true,
    Duration? timeout,
  }) {
    return _send(
      method: 'POST',
      path: path,
      queryParameters: queryParameters,
      body: body,
      requiresAuth: requiresAuth,
      timeout: timeout,
    );
  }

  Future<dynamic> put(
    String path, {
    Map<String, dynamic>? queryParameters,
    Object? body,
    bool requiresAuth = true,
    Duration? timeout,
  }) {
    return _send(
      method: 'PUT',
      path: path,
      queryParameters: queryParameters,
      body: body,
      requiresAuth: requiresAuth,
      timeout: timeout,
    );
  }

  Future<dynamic> delete(
    String path, {
    Map<String, dynamic>? queryParameters,
    Object? body,
    bool requiresAuth = true,
    Duration? timeout,
  }) {
    return _send(
      method: 'DELETE',
      path: path,
      queryParameters: queryParameters,
      body: body,
      requiresAuth: requiresAuth,
      timeout: timeout,
    );
  }

  Future<String> getText(
    String path, {
    Map<String, dynamic>? queryParameters,
    bool requiresAuth = true,
    Duration? timeout,
  }) async {
    final response = await _sendRaw(
      method: 'GET',
      path: path,
      queryParameters: queryParameters,
      requiresAuth: requiresAuth,
      timeout: timeout,
    );
    return response.body;
  }

  Future<dynamic> _send({
    required String method,
    required String path,
    Map<String, dynamic>? queryParameters,
    Object? body,
    bool requiresAuth = true,
    bool bypassCache = false,
    Duration? timeout,
  }) async {
    final cacheKey = _cacheKey(method, path, queryParameters);
    final isCacheableGet = method.toUpperCase() == 'GET' && !bypassCache;

    if (isCacheableGet) {
      final cached = _memoryCache[cacheKey];
      if (cached != null && DateTime.now().difference(cached.createdAt) < _defaultCacheTtl) {
        return cached.value;
      }

      final inFlight = _inFlightGets[cacheKey];
      if (inFlight != null) return inFlight;
    }

    final future = _sendRaw(
      method: method,
      path: path,
      queryParameters: queryParameters,
      body: body,
      requiresAuth: requiresAuth,
      timeout: timeout,
    ).then((response) {
      final contentType = response.headers['content-type'] ?? '';
      dynamic decoded;
      if (response.body.isEmpty) {
        decoded = null;
      } else if (contentType.contains('application/json')) {
        decoded = jsonDecode(response.body);
      } else {
        try {
          decoded = jsonDecode(response.body);
        } catch (_) {
          decoded = response.body;
        }
      }

      if (isCacheableGet) {
        _memoryCache[cacheKey] = _CachedApiResponse(decoded, DateTime.now());
      } else {
        _memoryCache.clear();
      }

      return decoded;
    }).whenComplete(() {
      if (isCacheableGet) _inFlightGets.remove(cacheKey);
    });

    if (isCacheableGet) _inFlightGets[cacheKey] = future;
    return future;
  }

  String _cacheKey(String method, String path, Map<String, dynamic>? queryParameters) {
    final entries = (queryParameters ?? <String, dynamic>{}).entries
        .where((entry) => entry.value != null && entry.value.toString().trim().isNotEmpty)
        .map((entry) => '${entry.key}=${entry.value}')
        .toList()
      ..sort();
    return '${method.toUpperCase()} $path?${entries.join('&')}';
  }

  Future<http.Response> _sendRaw({
    required String method,
    required String path,
    Map<String, dynamic>? queryParameters,
    Object? body,
    bool requiresAuth = true,
    Duration? timeout,
  }) async {
    final uri = _buildUri(path, queryParameters);
    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Accept': 'application/json, text/plain, */*',
    };

    if (requiresAuth) {
      final token = SessionManager.instance.token;
      if (token == null || SessionManager.instance.isExpired) {
        await SessionManager.instance.logout();
        throw ApiException(message: 'Session expired. Please sign in again.');
      }
      headers['Authorization'] = 'Bearer $token';
    }

    http.Response response;
    final encodedBody = body == null ? null : jsonEncode(body);
    final reqTimeout = timeout ?? _defaultTimeout;

    try {
      switch (method.toUpperCase()) {
        case 'GET':
          response = await _httpClient
              .get(uri, headers: headers)
              .timeout(reqTimeout);
          break;
        case 'POST':
          response = await _httpClient
              .post(uri, headers: headers, body: encodedBody)
              .timeout(reqTimeout);
          break;
        case 'PUT':
          response = await _httpClient
              .put(uri, headers: headers, body: encodedBody)
              .timeout(reqTimeout);
          break;
        case 'DELETE':
          response = await _httpClient
              .delete(uri, headers: headers, body: encodedBody)
              .timeout(reqTimeout);
          break;
        default:
          throw ApiException(message: 'Unsupported request method: $method');
      }
    } on ApiException {
      rethrow;
    } catch (error) {
      throw _networkError(error, uri);
    }

    if (response.statusCode == 401) {
      await SessionManager.instance.logout();
      throw ApiException(message: 'Session expired. Please sign in again.', statusCode: 401);
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _mapError(response);
    }

    return response;
  }

  ApiException _networkError(Object error, Uri uri) {
    final message = error.toString().toLowerCase();
    final host = uri.host.toLowerCase();

    if (error is TimeoutException) {
      return ApiException(
        message: 'Request timed out while contacting ${uri.toString()}. Check that the backend is running and reachable from this device.',
      );
    }

    if (message.contains('cleartext') || message.contains('not permitted')) {
      return ApiException(
        message: 'Android blocked HTTP traffic to ${uri.toString()}. Install this updated build again or switch the backend URL to HTTPS.',
      );
    }

    if (host == '127.0.0.1' || host == 'localhost') {
      return ApiException(
        message: 'Cannot reach ${uri.toString()}. localhost only works on the same device. On a real phone, use your computer LAN IP or adb reverse.',
      );
    }

    if (host == '10.0.2.2') {
      return ApiException(
        message: 'Cannot reach ${uri.toString()}. 10.0.2.2 only works on an Android emulator. Use your computer LAN IP on a real phone.',
      );
    }

    return ApiException(
      message: 'Could not reach the backend at ${uri.toString()}. Check the current URL, backend server, and firewall/network access.',
    );
  }

  Uri _buildUri(String path, Map<String, dynamic>? queryParameters) {
    final base = AppConfig.apiBaseUrl.endsWith('/')
        ? AppConfig.apiBaseUrl
        : '${AppConfig.apiBaseUrl}/';
    final resolved = Uri.parse(base).resolve(
      path.startsWith('/') ? path.substring(1) : path,
    );

    if (queryParameters == null || queryParameters.isEmpty) {
      return resolved;
    }

    final mapped = <String, String>{};
    for (final entry in queryParameters.entries) {
      final value = entry.value;
      if (value == null) continue;
      final stringValue = value.toString().trim();
      if (stringValue.isEmpty) continue;
      mapped[entry.key] = stringValue;
    }

    return resolved.replace(
      queryParameters: <String, String>{
        ...resolved.queryParameters,
        ...mapped,
      },
    );
  }

  ApiException _mapError(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return ApiException(
          message: decoded['message']?.toString() ??
              decoded['error']?.toString() ??
              'Request failed',
          statusCode: response.statusCode,
          details: decoded,
        );
      }
    } catch (_) {
      // Ignore and fall back to raw body.
    }

    return ApiException(
      message: response.body.isNotEmpty ? response.body : 'Request failed',
      statusCode: response.statusCode,
      details: response.body,
    );
  }
}
