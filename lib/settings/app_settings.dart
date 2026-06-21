import 'dart:io';
import 'package:equatable/equatable.dart';

import 'performance_preset.dart';

enum OutputLocation { nextToSource, customDir, appDocuments }
enum ConflictBehavior { ask, overwrite, autoRename }
enum ThemeModeSetting { system, light, dark }

class AppSettings extends Equatable {
  final bool trimPadding;
  final bool inPlace;
  final OutputLocation outputLocation;
  final String? customOutputDir;
  final ConflictBehavior conflictBehavior;
  final int parallelism;
  final ThemeModeSetting themeMode;
  final bool dynamicColor;
  final int themeSeedColor;
  final String? languageCode;
  final bool ignoreChecksum;

  /// CHD create compression codecs (chdman `-c`), comma-separated tokens such
  /// as `cdlz,cdzl,cdfl` / `cdzl,cdfl` / `cdzs,cdfl`.
  final String chdCodecs;

  /// Max CPU threads chdman may use (chdman `-np`). 0 means all processors.
  final int chdNumProcessors;

  /// CHD hunk size in bytes (chdman `-hs`). 0 means the chdman default.
  final int chdHunkBytes;

  /// Zstandard worker thread count for NSZ compression. 0 means default (cores - 2).
  final int nszThreadCount;

  /// IO Chunk Size in MB for NSZ compression. Default is 2 MB.
  final int nszChunkSizeMB;

  /// Whether to compress NCAs in parallel using isolates.
  final bool nszParallel;

  /// Selected performance tier. When not [PerformancePreset.custom], the
  /// processing parameters are resolved from this tier (adapting to the input)
  /// instead of the individual fields above; see [performance_preset.dart].
  final PerformancePreset performancePreset;

  const AppSettings({
    this.trimPadding = true,
    this.inPlace = false,
    this.outputLocation = OutputLocation.nextToSource,
    this.customOutputDir,
    this.conflictBehavior = ConflictBehavior.ask,
    this.parallelism = 1,
    this.themeMode = ThemeModeSetting.system,
    this.dynamicColor = true,
    this.themeSeedColor = 0xFF2196F3,
    this.languageCode,
    this.ignoreChecksum = false,
    this.chdCodecs = 'cdlz,cdzl,cdfl',
    this.chdNumProcessors = 0,
    this.chdHunkBytes = 0,
    this.nszThreadCount = 1,
    this.nszChunkSizeMB = 2,
    this.nszParallel = true,
    this.performancePreset = PerformancePreset.mid,
  });

  AppSettings copyWith({
    bool? trimPadding,
    bool? inPlace,
    OutputLocation? outputLocation,
    String? customOutputDir,
    ConflictBehavior? conflictBehavior,
    int? parallelism,
    ThemeModeSetting? themeMode,
    bool? dynamicColor,
    int? themeSeedColor,
    String? languageCode,
    bool clearLanguageCode = false,
    bool? ignoreChecksum,
    String? chdCodecs,
    int? chdNumProcessors,
    int? chdHunkBytes,
    int? nszThreadCount,
    int? nszChunkSizeMB,
    bool? nszParallel,
    PerformancePreset? performancePreset,
  }) {
    return AppSettings(
      trimPadding: trimPadding ?? this.trimPadding,
      inPlace: inPlace ?? this.inPlace,
      outputLocation: outputLocation ?? this.outputLocation,
      customOutputDir: customOutputDir ?? this.customOutputDir,
      conflictBehavior: conflictBehavior ?? this.conflictBehavior,
      parallelism: parallelism ?? this.parallelism,
      themeMode: themeMode ?? this.themeMode,
      dynamicColor: dynamicColor ?? this.dynamicColor,
      themeSeedColor: themeSeedColor ?? this.themeSeedColor,
      languageCode: clearLanguageCode ? null : (languageCode ?? this.languageCode),
      ignoreChecksum: ignoreChecksum ?? this.ignoreChecksum,
      chdCodecs: chdCodecs ?? this.chdCodecs,
      chdNumProcessors: chdNumProcessors ?? this.chdNumProcessors,
      chdHunkBytes: chdHunkBytes ?? this.chdHunkBytes,
      nszThreadCount: nszThreadCount ?? this.nszThreadCount,
      nszChunkSizeMB: nszChunkSizeMB ?? this.nszChunkSizeMB,
      nszParallel: nszParallel ?? this.nszParallel,
      performancePreset: performancePreset ?? this.performancePreset,
    );
  }

  factory AppSettings.defaults() {
    int maxCores = 1;
    try {
      maxCores = Platform.numberOfProcessors;
    } catch (_) {}
    // Default to max 4 for I/O heavy tasks, but allow user to increase up to 16 in settings
    int defaultParallelism = maxCores.clamp(1, 4);
    
    bool isMobile = false;
    try {
      isMobile = Platform.isAndroid || Platform.isIOS;
    } catch (_) {}

    return AppSettings(
      parallelism: defaultParallelism,
      outputLocation: OutputLocation.nextToSource,
      nszParallel: true,
      themeSeedColor: 0xFF2196F3,
    );
  }

  @override
  List<Object?> get props => [
        trimPadding,
        inPlace,
        outputLocation,
        customOutputDir,
        conflictBehavior,
        parallelism,
        themeMode,
        dynamicColor,
        themeSeedColor,
        languageCode,
        ignoreChecksum,
        chdCodecs,
        chdNumProcessors,
        chdHunkBytes,
        nszThreadCount,
        nszChunkSizeMB,
        nszParallel,
        performancePreset,
      ];
}

extension AppSettingsTuning on AppSettings {
  /// Resolves the effective processing parameters for the current
  /// [performancePreset]. For [PerformancePreset.custom] the individual settings
  /// fields are returned unchanged (legacy behavior, with NSZ NCA concurrency
  /// left unbounded). [input] lets the resolver adapt NSZ concurrency to the
  /// archive's NCA layout; [customCompressionLevel] supplies the UI slider value
  /// used in custom mode.
  ResolvedTuning resolveTuning({
    InputProfile? input,
    int customCompressionLevel = 15,
  }) {
    return resolvePreset(
      tier: performancePreset,
      input: input,
      customFallback: ResolvedTuning(
        nszThreadCount: nszThreadCount,
        nszChunkSizeMB: nszChunkSizeMB,
        nszParallel: nszParallel,
        // Unbounded: preserve the pre-preset behavior of spawning every NCA
        // isolate at once when the user explicitly chooses Custom.
        nszMaxConcurrentNcas: 1 << 30,
        compressionLevel: customCompressionLevel,
        chdCodecs: chdCodecs,
        chdNumProcessors: chdNumProcessors,
        chdHunkBytes: chdHunkBytes,
        parallelism: parallelism,
      ),
    );
  }
}
