import 'dart:async';
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
  bool _isFinalizing = false;
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

    // Check if Daraz redirected back to Render callback endpoint
    final isCallbackPath = url.contains('/api/stores/oauth/callback') ||
        url.contains('/api/stores/auth/callback');

    // Case A: App custom scheme reached
    if (isCustomScheme) {
      _hasHandledCallback = true;
      final oauthStatus = uri.queryParameters['oauth'];
      final message = uri.queryParameters['message']?.trim() ?? '';

      if (oauthStatus == 'success' || oauthStatus == null) {
        Navigator.of(context).pop(true);
      } else {
        Navigator.of(context).pop(message.isNotEmpty ? message : 'Authorization failed');
      }
      return true;
    }

    // Case B: Daraz sent auth code to Render callback endpoint
    if (isCallbackPath && uri.queryParameters.containsKey('code')) {
      if (!_isFinalizing && mounted) {
        setState(() => _isFinalizing = true);
      }
      // Give Render 1.5 seconds to exchange code and store the token in DB, then auto-close with success!
      Timer(const Duration(milliseconds: 1600), () {
        if (mounted && !_hasHandledCallback) {
          _hasHandledCallback = true;
          Navigator.of(context).pop(true);
        }
      });
      return false; // let request reach Render
    }

    // Case C: Render callback returned with oauth query param
    if (isCallbackPath && uri.queryParameters.containsKey('oauth')) {
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
          onPressed: () => Navigator.of(context).pop(_isFinalizing ? true : false),
          tooltip: 'Close',
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
              _isFinalizing ? 'Saving connection...' : 'Daraz In-App Authorization',
              style: TextStyle(
                fontSize: 11,
                color: _isFinalizing ? AppTheme.success : AppTheme.textMutedColor(context),
                fontWeight: _isFinalizing ? FontWeight.bold : FontWeight.normal,
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
        bottom: (_isLoading || _isFinalizing)
            ? PreferredSize(
                preferredSize: const Size.fromHeight(3),
                child: LinearProgressIndicator(
                  value: _progress > 0 && _progress < 1 && !_isFinalizing ? _progress : null,
                  backgroundColor: isDark ? Colors.grey[850] : Colors.grey[200],
                  valueColor: AlwaysStoppedAnimation<Color>(
                    _isFinalizing ? AppTheme.success : AppTheme.primary,
                  ),
                  minHeight: 3,
                ),
              )
            : null,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            WebViewWidget(controller: _controller),
            if (_isFinalizing)
              Container(
                color: Colors.black54,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    decoration: BoxDecoration(
                      color: AppTheme.cardColor(context),
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(color: Colors.black26, blurRadius: 10, offset: Offset(0, 4))
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 36,
                          height: 36,
                          child: CircularProgressIndicator(strokeWidth: 3, color: AppTheme.primary),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Connecting ${widget.store.name}...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimaryColor(context),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Saving authorization token',
                          style: TextStyle(fontSize: 12, color: AppTheme.textMutedColor(context)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
