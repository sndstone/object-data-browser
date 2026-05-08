import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/s3_browser_app.dart';
import 'services/app_bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Show a visible error screen in release builds instead of a blank white
  // window, which happens when Flutter's default release-mode ErrorWidget
  // renders an invisible placeholder.
  ErrorWidget.builder = (FlutterErrorDetails details) {
    if (kDebugMode) {
      return ErrorWidget(details.exception);
    }
    return Material(
      color: const Color(0xFFF44336),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SelectableText(
            'An error occurred. Please restart the app.\n\n'
            '${details.exception}',
            style: const TextStyle(color: Colors.white, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  };

  try {
    final controller = await AppBootstrap.initialize();
    runApp(S3BrowserApp(controller: controller));
  } catch (error, stack) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(
                'Failed to start the app.\n\n$error\n\n$stack',
                style: const TextStyle(color: Colors.red, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
