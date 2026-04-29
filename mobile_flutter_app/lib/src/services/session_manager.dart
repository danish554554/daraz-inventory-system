import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api_client.dart';
import 'api_exception.dart';

class SessionManager extends ChangeNotifier {
  SessionManager._();

  static final SessionManager instance = SessionManager._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _tokenKey = 'admin_token';
  static const String _usernameKey = 'admin_user';
  static const String _expiresAtKey = 'admin_token_expires_at';

  bool _isBootstrapping = true;
  String? _token;
  String? _username;
  DateTime? _expiresAt;

  bool get isBootstrapping => _isBootstrapping;
  bool get isAuthenticated => _token != null && !isExpired;
  String? get token => _token;
  String get username => _username ?? 'Admin User';
  DateTime? get expiresAt => _expiresAt;

  bool get isExpired {
    if (_token == null) return true;
    if (_expiresAt != null) {
      return _expiresAt!.isBefore(DateTime.now());
    }

    final payload = _parseTokenPayload(_token!);
    final exp = payload['exp'];
    if (exp is int) {
      return DateTime.fromMillisecondsSinceEpoch(exp * 1000)
          .isBefore(DateTime.now());
    }
    return false;
  }

  Future<void> restore() async {
    _isBootstrapping = true;
    notifyListeners();

    try {
      _token = await _storage.read(key: _tokenKey);
      _username = await _storage.read(key: _usernameKey);
      final expiresAtRaw = await _storage.read(key: _expiresAtKey);
      if (expiresAtRaw != null && expiresAtRaw.isNotEmpty) {
        _expiresAt = DateTime.tryParse(expiresAtRaw);
      }

      if (isExpired) {
        await logout(notify: false);
      } else if (_token != null) {
        try {
          final response = await ApiClient.instance.get('/auth/me');
          final map = response is Map<String, dynamic> ? response : <String, dynamic>{};
          final user = map['user'];
          if (user is Map<String, dynamic>) {
            _username = user['username']?.toString() ?? _username;
            if (_username != null) {
              await _storage.write(key: _usernameKey, value: _username);
            }
          }

          final session = map['session'];
          final sessionExpiresAt = session is Map<String, dynamic>
              ? session['expiresAt']?.toString()
              : null;
          if (sessionExpiresAt != null && sessionExpiresAt.isNotEmpty) {
            _expiresAt = DateTime.tryParse(sessionExpiresAt);
            if (_expiresAt != null) {
              await _storage.write(
                key: _expiresAtKey,
                value: _expiresAt!.toIso8601String(),
              );
            }
          }
        } on ApiException {
          await logout(notify: false);
        } catch (_) {
          // Keep the local session when the backend is temporarily unreachable.
        }
      }
    } finally {
      _isBootstrapping = false;
      notifyListeners();
    }
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    final response = await ApiClient.instance.post(
      '/auth/login',
      body: {
        'username': username.trim(),
        'password': password,
      },
      requiresAuth: false,
    );

    final map = response is Map<String, dynamic>
        ? response
        : throw ApiException(message: 'Unexpected login response');

    final token = map['token']?.toString();
    if (token == null || token.isEmpty) {
      throw ApiException(message: 'Server did not return a session token');
    }

    _token = token;
    _username = map['user'] is Map<String, dynamic>
        ? (map['user']['username']?.toString() ?? username.trim())
        : username.trim();

    final expiresAtRaw = map['expiresAt']?.toString();
    _expiresAt = expiresAtRaw != null ? DateTime.tryParse(expiresAtRaw) : null;

    await _storage.write(key: _tokenKey, value: _token);
    await _storage.write(key: _usernameKey, value: _username);
    if (_expiresAt != null) {
      await _storage.write(key: _expiresAtKey, value: _expiresAt!.toIso8601String());
    } else {
      await _storage.delete(key: _expiresAtKey);
    }

    notifyListeners();
  }

  Future<void> logout({bool notify = true}) async {
    _token = null;
    _username = null;
    _expiresAt = null;

    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _expiresAtKey);

    if (notify) {
      notifyListeners();
    }
  }

  Future<String?> readPreference(String key) {
    return _storage.read(key: key);
  }

  Future<void> writePreference(String key, String value) async {
    await _storage.write(key: key, value: value);
  }

  Map<String, dynamic> _parseTokenPayload(String token) {
    final parts = token.split('.');
    if (parts.length != 3) return <String, dynamic>{};
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final payload = jsonDecode(decoded);
      if (payload is Map<String, dynamic>) {
        return payload;
      }
      return <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
}
