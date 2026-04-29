import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

class AppConfig {
  AppConfig._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _apiBaseUrlKey = 'api_base_url_v2';
  static const String _compileTimeApiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http:// 192.168.0.106:5000/api',
  );

  static String? _runtimeApiBaseUrl;

  static const String appName = 'Daraz Inventory Control';
  static const String oauthCallbackScheme = 'darazinventory';
  static const String oauthCallbackHost = 'oauth-callback';

  static String get defaultApiBaseUrl => _normalizeApiBaseUrl(_compileTimeApiBaseUrl);
  static String get apiBaseUrl => _runtimeApiBaseUrl ?? defaultApiBaseUrl;
  static String get oauthCallbackUrl => '$oauthCallbackScheme://$oauthCallbackHost';

  static Future<void> load() async {
    final saved = await _storage.read(key: _apiBaseUrlKey);
    if (saved != null && saved.trim().isNotEmpty) {
      _runtimeApiBaseUrl = _normalizeApiBaseUrl(saved);
    }
  }

  static Future<void> updateApiBaseUrl(String value) async {
    final normalized = _normalizeApiBaseUrl(value);
    _runtimeApiBaseUrl = normalized;
    await _storage.write(key: _apiBaseUrlKey, value: normalized);
  }

  static Future<void> resetApiBaseUrl() async {
    _runtimeApiBaseUrl = null;
    await _storage.delete(key: _apiBaseUrlKey);
  }

  static String _normalizeApiBaseUrl(String value) {
    var normalized = value.trim();
    if (normalized.isEmpty) {
      return _normalizeApiBaseUrl(_compileTimeApiBaseUrl);
    }

    if (!normalized.startsWith('http://') && !normalized.startsWith('https://')) {
      normalized = 'http://$normalized';
    }

    final parsed = Uri.parse(normalized);
    var path = parsed.path.trim();
    if (path.isEmpty || path == '/') {
      path = '/api';
    } else {
      path = path.replaceAll(RegExp(r'/+$'), '');
      if (!path.toLowerCase().endsWith('/api')) {
        path = '$path/api';
      }
    }

    return parsed.replace(path: path).toString().replaceFirst(RegExp(r'/+$'), '');
  }

  static Future<String?> testApiBaseUrl(String value) async {
    final normalized = _normalizeApiBaseUrl(value);
    final apiUri = Uri.parse(normalized);
    final healthUri = apiUri.replace(path: '/health', query: '');

    try {
      final response = await http
          .get(
            healthUri,
            headers: const <String, String>{'Accept': 'application/json'},
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return null;
      }

      return 'Server responded with status ${response.statusCode}. Verify that the backend is running and reachable at ${healthUri.toString()}.';
    } on TimeoutException {
      return 'Connection timed out. Check the server URL, network access, and whether the backend is running.';
    } catch (error) {
      final message = error.toString().toLowerCase();
      final host = apiUri.host.toLowerCase();

      if (message.contains('cleartext') || message.contains('not permitted')) {
        return 'Android is blocking HTTP traffic. Reinstall this updated build or use an HTTPS backend URL.';
      }

      if (host == '127.0.0.1' || host == 'localhost') {
        return '127.0.0.1 / localhost only works on the same device. On a real phone, use your computer LAN IP or adb reverse.';
      }

      if (host == '10.0.2.2') {
        return '10.0.2.2 only works on an Android emulator. On a real phone, use your computer LAN IP or adb reverse.';
      }

      return 'Could not reach the backend health endpoint. Check the server, firewall, and current URL: ${healthUri.toString()}.';
    }
  }
}
