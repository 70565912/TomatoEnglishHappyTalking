import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'core/config/app_config.dart';
import 'core/logging/tomato_logger.dart';
import 'core/theme/app_theme.dart';
import 'core/router/app_router.dart';
import 'core/webview/webview_environment.dart';
import 'services/database_service.dart';

void main() {
  runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      await TomatoLogger.initialize();
      FlutterError.onError = (details) {
        TomatoLogger.error(
          category: 'startup',
          event: 'flutter.error',
          message: details.exceptionAsString(),
          error: details.exception,
          stackTrace: details.stack,
        );
        FlutterError.presentError(details);
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        TomatoLogger.fatal(
          category: 'startup',
          event: 'platform.unhandled_error',
          message: error.toString(),
          error: error,
          stackTrace: stackTrace,
        );
        return true;
      };

      TomatoLogger.info(
        category: 'startup',
        event: 'app.start',
        data: {
          'platform': defaultTargetPlatform.name,
          'kIsWeb': kIsWeb,
        },
      );

      // Initialize sqflite FFI for Windows / Linux / macOS desktop
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux ||
              defaultTargetPlatform == TargetPlatform.macOS)) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        TomatoLogger.info(
          category: 'startup',
          event: 'database.ffi_initialized',
        );
      }

      await AppConfig.seedSecureStorageFromEnvironment();
      TomatoLogger.info(category: 'config', event: 'secure_storage.seeded');

      await initializeTomatoWebViewEnvironment();
      TomatoLogger.info(
        category: 'webview',
        event: tomatoWebViewEnvironmentError == null
            ? 'environment.initialized'
            : 'environment.error',
        data: {
          'hasEnvironment': tomatoWebViewEnvironment != null,
          'error': tomatoWebViewEnvironmentError,
        },
      );

      await initializeTomatoWebUiServer();
      TomatoLogger.info(
        category: 'webview',
        event: tomatoWebUiServerError == null
            ? 'local_server.started'
            : 'local_server.error',
        data: {
          'url': tomatoWebUiLocalUrl,
          'hasServer': tomatoWebUiServer != null,
          'error': tomatoWebUiServerError,
        },
      );
      TomatoLogger.info(
        category: 'startup',
        event: 'runtime.paths',
        data: {
          'databaseDirectory': await DatabaseService.databaseDirectory,
          'logDirectory': TomatoLogger.logDirectory?.absolute.path,
        },
      );

      runApp(
        const ProviderScope(
          child: TomatoEnglishHappyTalkingApp(),
        ),
      );
    },
    (error, stackTrace) {
      TomatoLogger.fatal(
        category: 'startup',
        event: 'zone.unhandled_error',
        message: error.toString(),
        error: error,
        stackTrace: stackTrace,
      );
    },
  );
}

class TomatoEnglishHappyTalkingApp extends ConsumerWidget {
  const TomatoEnglishHappyTalkingApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      title: 'Tomato English Happy Talking',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      routerConfig: appRouter,
    );
  }
}
