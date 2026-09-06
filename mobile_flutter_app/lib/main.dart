import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/services/app_config.dart';
import 'src/services/session_manager.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  PaintingBinding.instance.imageCache.maximumSize = 100;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 << 20;
  await AppConfig.load();
  await SessionManager.instance.restore();
  runApp(DarazInventoryApp(sessionManager: SessionManager.instance));
}
