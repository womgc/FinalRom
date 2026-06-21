import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:final_rom/l10n/app_localizations.dart';

import 'settings/app_settings.dart';
import 'settings/settings_cubit.dart';
import 'router.dart';
import 'ui/theme.dart';

class CryptoApp extends StatelessWidget {
  const CryptoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, AppSettings>(
      builder: (context, settings) {
        return DynamicColorBuilder(
          builder: (lightDynamic, darkDynamic) {
            ColorScheme? lightScheme;
            ColorScheme? darkScheme;

            if (settings.dynamicColor) {
              lightScheme = lightDynamic;
              darkScheme = darkDynamic;
            }

            ThemeMode flutterThemeMode;
            switch (settings.themeMode) {
              case ThemeModeSetting.system:
                flutterThemeMode = ThemeMode.system;
                break;
              case ThemeModeSetting.light:
                flutterThemeMode = ThemeMode.light;
                break;
              case ThemeModeSetting.dark:
                flutterThemeMode = ThemeMode.dark;
                break;
            }

            return MaterialApp.router(
              title: 'Final ROM',
              theme: AppTheme.buildThemeWithColor(Brightness.light, lightScheme, Color(settings.themeSeedColor)),
              darkTheme: AppTheme.buildThemeWithColor(Brightness.dark, darkScheme, Color(settings.themeSeedColor)),
              themeMode: flutterThemeMode,
              debugShowCheckedModeBanner: false,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: settings.languageCode != null ? Locale(settings.languageCode!) : null,
              routerConfig: appRouter,
            );
          },
        );
      },
    );
  }
}
