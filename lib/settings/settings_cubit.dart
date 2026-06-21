import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_settings.dart';
import 'performance_preset.dart';

class SettingsCubit extends Cubit<AppSettings> {
  final SharedPreferences _prefs;

  SettingsCubit(this._prefs) : super(_loadSettings(_prefs));

  static AppSettings _loadSettings(SharedPreferences prefs) {
    final defaults = AppSettings.defaults();
    
    return AppSettings(
      trimPadding: prefs.getBool('trimPadding') ?? defaults.trimPadding,
      inPlace: prefs.getBool('inPlace') ?? defaults.inPlace,
      outputLocation: OutputLocation.values[
          prefs.getInt('outputLocation') ?? defaults.outputLocation.index],
      customOutputDir: prefs.getString('customOutputDir') ?? defaults.customOutputDir,
      conflictBehavior: ConflictBehavior.values[
          prefs.getInt('conflictBehavior') ?? defaults.conflictBehavior.index],
      parallelism: prefs.getInt('parallelism') ?? defaults.parallelism,
      themeMode: ThemeModeSetting.values[
          prefs.getInt('themeMode') ?? defaults.themeMode.index],
      dynamicColor: prefs.getBool('dynamicColor') ?? defaults.dynamicColor,
      themeSeedColor: prefs.getInt('themeSeedColor') ?? defaults.themeSeedColor,
      languageCode: prefs.getString('languageCode') ?? defaults.languageCode,
      ignoreChecksum: prefs.getBool('ignoreChecksum') ?? defaults.ignoreChecksum,
      chdCodecs: prefs.getString('chdCodecs') ?? defaults.chdCodecs,
      chdNumProcessors: prefs.getInt('chdNumProcessors') ?? defaults.chdNumProcessors,
      chdHunkBytes: prefs.getInt('chdHunkBytes') ?? defaults.chdHunkBytes,
      nszThreadCount: prefs.getInt('nszThreadCount') ?? defaults.nszThreadCount,
      nszChunkSizeMB: prefs.getInt('nszChunkSizeMB') ?? defaults.nszChunkSizeMB,
      nszParallel: prefs.getBool('nszParallel') ?? defaults.nszParallel,
      performancePreset: PerformancePreset.values[
          prefs.getInt('performancePreset') ?? defaults.performancePreset.index],
    );
  }

  Future<void> updateSettings(AppSettings newSettings) async {
    emit(newSettings);
    await Future.wait([
      _prefs.setBool('trimPadding', newSettings.trimPadding),
      _prefs.setBool('inPlace', newSettings.inPlace),
      _prefs.setInt('outputLocation', newSettings.outputLocation.index),
      if (newSettings.customOutputDir != null)
        _prefs.setString('customOutputDir', newSettings.customOutputDir!)
      else
        _prefs.remove('customOutputDir'),
      _prefs.setInt('conflictBehavior', newSettings.conflictBehavior.index),
      _prefs.setInt('parallelism', newSettings.parallelism),
      _prefs.setInt('themeMode', newSettings.themeMode.index),
      _prefs.setBool('dynamicColor', newSettings.dynamicColor),
      _prefs.setInt('themeSeedColor', newSettings.themeSeedColor),
      if (newSettings.languageCode != null)
        _prefs.setString('languageCode', newSettings.languageCode!)
      else
        _prefs.remove('languageCode'),
      _prefs.setBool('ignoreChecksum', newSettings.ignoreChecksum),
      _prefs.setString('chdCodecs', newSettings.chdCodecs),
      _prefs.setInt('chdNumProcessors', newSettings.chdNumProcessors),
      _prefs.setInt('chdHunkBytes', newSettings.chdHunkBytes),
      _prefs.setInt('nszThreadCount', newSettings.nszThreadCount),
      _prefs.setInt('nszChunkSizeMB', newSettings.nszChunkSizeMB),
      _prefs.setBool('nszParallel', newSettings.nszParallel),
      _prefs.setInt('performancePreset', newSettings.performancePreset.index),
    ]);
  }
}
