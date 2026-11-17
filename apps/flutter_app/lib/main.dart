import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app/s3_browser_app.dart';
import 'services/app_bootstrap.dart';
import 'controllers/app_controller.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final family in ['Inter', 'Sora']) {
      yield LicenseEntryWithLineBreaks([family],
          await rootBundle.loadString('assets/fonts/$family-OFL.txt'));
    }
  });

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

  runApp(const BootstrapApp());
}

/// Paint a window before platform I/O or a Keychain authorization can begin.
class BootstrapApp extends StatefulWidget {
  const BootstrapApp({super.key, this.initialize = AppBootstrap.initialize});

  final Future<AppController> Function() initialize;

  @override
  State<BootstrapApp> createState() => _BootstrapAppState();
}

class _BootstrapAppState extends State<BootstrapApp> {
  AppController? _controller;
  Object? _error;
  StackTrace? _stack;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  Future<void> _start() async {
    try {
      final controller = await widget.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error, stack) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _stack = stack;
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null) return S3BrowserApp(controller: controller);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(
        scalePercent: 100,
        desktopCompact: AppTheme.isDesktopPlatform(defaultTargetPlatform),
      ),
      home: Scaffold(
        body: Center(
          child: _error == null
              ? const Text('Loading…')
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: SelectableText(
                    'Failed to start the app.\n\n$_error\n\n$_stack',
                    style: const TextStyle(color: Colors.red, fontSize: 13),
                    textAlign: TextAlign.center,
                  ),
                ),
        ),
      ),
    );
  }
}
