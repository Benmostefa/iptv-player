import 'package:another_iptv_player/services/update_service.dart';
import 'package:another_iptv_player/services/kids_mode.dart';
import 'package:another_iptv_player/controllers/playlist_controller.dart';
import 'package:another_iptv_player/screens/app_initializer_screen.dart';
import 'package:flutter/material.dart';
import 'package:another_iptv_player/services/service_locator.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'controllers/locale_provider.dart';
import 'controllers/theme_provider.dart';
import 'l10n/app_localizations.dart';
import 'l10n/supported_languages.dart';
import 'utils/app_themes.dart';
import 'utils/mouse_navigation.dart';

Future<void> main() async {
  await setupServiceLocator();
  await KidsMode.load();
  UpdateService.cleanupOldFiles();
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => LocaleProvider()),
        ChangeNotifierProvider(create: (_) => PlaylistController()),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final localeProvider = Provider.of<LocaleProvider>(context);
    final themeProvider = Provider.of<ThemeProvider>(context);

    return MaterialApp(
      locale: localeProvider.locale,
      supportedLocales:
      supportedLanguages.map((lang) => Locale(lang['code'])).toList(),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      title: 'Another IPTV Player',
      theme: AppThemes.lightTheme,
      darkTheme: AppThemes.darkTheme,
      themeMode: themeProvider.themeMode,
      navigatorKey: appNavigatorKey,
      navigatorObservers: [MouseNavigationObserver.instance],
      // Boutons Retour / Avancer de la souris.
      builder: (context, child) =>
          MouseNavigationListener(child: child ?? const SizedBox.shrink()),
      home: AppInitializerScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
