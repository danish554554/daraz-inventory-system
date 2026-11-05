import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/app_models.dart';
import '../services/app_config.dart';
import '../widgets/app_theme.dart';

class DarazAuthWebViewScreen extends StatefulWidget {
  final StoreModel store;
  final String authorizeUrl;

  const DarazAuthWebViewScreen({
    super.key,
    required this.store,
    required this.authorizeUrl,
  });

  @override
  State<DarazAuthWebViewScreen> createState() => _DarazAuthWebViewScreenState();
}

class _DarazAuthWebViewScreenState extends State<DarazAuthWebViewScreen> {
  late final WebViewController _controller;
  double _progress = 0;
  bool _isLoading = true;
  bool _hasHandledCallback = false;

  // Desktop user agent prevents Daraz from redirecting mobile browsers to the Play Store
  static const String _desktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUserAgent)
      ..setBackgroundColor(Colors.white)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            if (mounted) {
              setState(() => _progress = progress / 100);
            }
          },
          onPageStarted: (String url) {
            if (mounted) setState(() => _isLoading = true);
            _checkCallback(url);
          },
          onPageFinished: (String url) {
            if (mounted) setState(() => _isLoading = false);
            _checkCallback(url);
          },
          onWebResourceError: (WebResourceError error) {
            if (error.url != null) {
              _checkCallback(error.url!);
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            if (_checkCallback(request.url)) {
              return NavigationDecision.prevent;
            }
            // Block any Android intent or Play Store redirects that Daraz mobile pages might try
            if (request.url.contains('play.google.com') || request.url.startsWith('market://')) {
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.authorizeUrl));
  }

  bool _checkCallback(String url) {
    if (_hasHandledCallback || url.isEmpty) return false;

    final uri = Uri.tryParse(url);
    if (uri == null) return false;

    // Check for custom app scheme: darazinventory://oauth-callback
    final isCustomScheme = uri.scheme == AppConfig.oauthCallbackScheme ||
        url.startsWith(AppConfig.oauthCallbackUrl);

    // Also check if Render callback finished and returned query parameters
    final isRenderCallback = (url.contains('/api/stores/oauth/callback') ||
            url.contains('/api/stores/auth/callback')) &&
        uri.queryParameters.containsKey('oauth');

    if (isCustomScheme || isRenderCallback) {
      _hasHandledCallback = true;
      final oauthStatus = uri.queryParameters['oauth'];
      final message = uri.queryParameters['message']?.trim() ?? '';

      if (oauthStatus == 'success') {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context).pop(message.isNotEmpty ? message : 'Authorization failed');
      }
      return true;
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: AppTheme.backgroundColor(context),
      appBar: AppBar(
        backgroundColor: AppTheme.cardColor(context),
        elevation: 0.5,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(false),
          tooltip: 'Cancel',
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Connect ${widget.store.name}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimaryColor(context),
              ),
            ),
            Text(
              'Daraz In-App Authorization',
              style: TextStyle(
                fontSize: 11,
                color: AppTheme.textMutedColor(context),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: () => _controller.reload(),
            tooltip: 'Reload',
          ),
        ],
        bottom: _isLoading
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _progress > 0 && _progress < 1 ? _progress : null,
                  backgroundColor: isDark ? Colors.grey[850] : Colors.grey[200],
                  valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
                  minHeight: 3,
                ),
              )
            : null,
      ),
      body: SafeArea(
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
