import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../settings/app_settings.dart';
import '../settings/performance_preset.dart';
import '../settings/settings_cubit.dart';
import '../services/file_service.dart';
import '../services/logger_service.dart';
import 'package:final_rom/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'android_file_picker.dart';
import 'widgets/dialogs.dart';

/// Sentinel selected in the codec dropdown to open a free-text editor.
const String _customCodecKey = '__chd_custom__';

/// Common CD codec presets shown in the settings dropdown. Keys are the raw
/// chdman `-c` strings; values are friendly labels.
const Map<String, String> _chdCodecPresets = {
  'cdlz,cdzl,cdfl': 'Best size (LZMA)',
  'cdzl,cdfl': 'Fastest (Deflate)',
  'cdzs,cdfl': 'Zstandard',
};

/// Languages the app ships translations for. Keys are locale codes (matching
/// the app_<code>.arb files); values are the language's own native name, shown
/// untranslated as is conventional in a language picker.
const Map<String, String> _supportedLanguages = {
  'en': 'English',
  'ar': 'العربية',
  'es': 'Español',
  'fr': 'Français',
  'ja': '日本語',
};

const Map<String, int> _presetColors = {
  'Blue': 0xFF2196F3,
  'Purple': 0xFF9C27B0,
  'Orange': 0xFFFF9800,
  'Green': 0xFF4CAF50,
  'Pink': 0xFFE91E63,
  'Teal': 0xFF009688,
  'Amber': 0xFFFFC107,
};

final int _maxCores = () {
  try {
    return Platform.numberOfProcessors;
  } catch (_) {
    return 16;
  }
}();

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(loc.settingsTitle)),
      body: BlocBuilder<SettingsCubit, AppSettings>(
        builder: (context, settings) {
          final cubit = context.read<SettingsCubit>();
          // When a non-custom preset is active, the resolver overrides every
          // manual tuning value, so those controls are shown disabled.
          final bool tuningLocked = settings.performancePreset != PerformancePreset.custom;
          // Effective tuning the converters will actually use. In custom mode this
          // is the manual values verbatim; under a preset it is the resolver's
          // overrides, which is what the (locked) tiles should display.
          final effective = settings.resolveTuning();
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 800),
              child: ListView(
                padding: const EdgeInsets.all(16.0),
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Appearance & Localization',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  ListTile(
                    title: Text(loc.language),
                    trailing: _buildDropdown<String?>(
                      context: context,
                      initialSelection: settings.languageCode,
                      width: 180,
                      entries: [
                        DropdownMenuEntry(value: null, label: loc.languageSystem),
                        ..._supportedLanguages.entries.map(
                          (e) => DropdownMenuEntry(value: e.key, label: e.value),
                        ),
                      ],
                      onSelected: (val) {
                        // Pass clearLanguageCode so selecting "System Default" (null)
                        // actually clears the override instead of being ignored.
                        cubit.updateSettings(
                          settings.copyWith(languageCode: val, clearLanguageCode: val == null),
                        );
                      },
                    ),
                  ),
                  ListTile(
                    title: Text(loc.themeMode),
                    trailing: _buildDropdown<ThemeModeSetting>(
                      context: context,
                      initialSelection: settings.themeMode,
                      width: 180,
                      entries: ThemeModeSetting.values
                          .map(
                            (v) => DropdownMenuEntry<ThemeModeSetting>(
                              value: v,
                              label: _getThemeText(v, loc),
                            ),
                          )
                          .toList(),
                      onSelected: (val) {
                        if (val != null) cubit.updateSettings(settings.copyWith(themeMode: val));
                      },
                    ),
                  ),
                  ListTile(
                    title: const Text('Theme Accent Color'),
                    subtitle: const Text('Choose a custom seed color for the app theme'),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: Builder(
                      builder: (context) {
                        final theme = Theme.of(context);
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: _presetColors.entries.map((entry) {
                            final colorVal = entry.value;
                            final isSelected =
                                settings.themeSeedColor == colorVal && !settings.dynamicColor;
                            return GestureDetector(
                              onTap: () {
                                cubit.updateSettings(
                                  settings.copyWith(themeSeedColor: colorVal, dynamicColor: false),
                                );
                              },
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  color: Color(colorVal),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: isSelected
                                        ? theme.colorScheme.primary
                                        : Colors.transparent,
                                    width: 3,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.15),
                                      blurRadius: 6,
                                      offset: const Offset(0, 3),
                                    ),
                                  ],
                                ),
                                child: isSelected
                                    ? const Icon(Icons.check, color: Colors.white, size: 20)
                                    : null,
                              ),
                            );
                          }).toList(),
                        );
                      },
                    ),
                  ),
                  SwitchListTile(
                    title: Text(loc.dynamicColor),
                    value: settings.dynamicColor,
                    onChanged: (val) => cubit.updateSettings(settings.copyWith(dynamicColor: val)),
                  ),
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Processing Options',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  if (FileService.supportsInPlace) ...[
                    ListTile(
                      title: Text(loc.outputHandling),
                      trailing: _buildDropdown<bool>(
                        context: context,
                        initialSelection: settings.inPlace,
                        width: 180,
                        entries: [
                          DropdownMenuEntry(value: false, label: loc.outputHandlingNewFile),
                          DropdownMenuEntry(value: true, label: loc.outputHandlingOverwrite),
                        ],
                        onSelected: (val) {
                          if (val != null) cubit.updateSettings(settings.copyWith(inPlace: val));
                        },
                      ),
                    ),
                  ],
                  ListTile(
                    title: Text(loc.outputLocation),
                    subtitle:
                        settings.outputLocation == OutputLocation.customDir &&
                            settings.customOutputDir != null
                        ? Text(settings.customOutputDir!)
                        : null,
                    trailing: _buildDropdown<OutputLocation>(
                      context: context,
                      initialSelection: settings.outputLocation,
                      width: 220,
                      entries: [
                        DropdownMenuEntry(
                          value: OutputLocation.nextToSource,
                          label: loc.outputLocationNextToSource,
                        ),
                        DropdownMenuEntry(
                          value: OutputLocation.customDir,
                          label: loc.outputLocationCustom,
                        ),
                        DropdownMenuEntry(
                          value: OutputLocation.appDocuments,
                          label: loc.outputLocationAppDocs,
                        ),
                      ],
                      onSelected: (val) async {
                        if (val == null) return;
                        String? customDir;
                        if (val == OutputLocation.customDir) {
                          if (Platform.isAndroid && context.mounted) {
                            customDir = await AndroidFilePicker.pickDirectory(context);
                          } else {
                            customDir = await FileService.pickOutputFolder();
                          }
                          if (customDir == null) return; // user cancelled
                        }
                        cubit.updateSettings(
                          settings.copyWith(outputLocation: val, customOutputDir: customDir),
                        );
                      },
                    ),
                  ),
                  ListTile(
                    title: Text(loc.conflictBehavior),
                    trailing: _buildDropdown<ConflictBehavior>(
                      context: context,
                      initialSelection: settings.conflictBehavior,
                      width: 180,
                      entries: ConflictBehavior.values
                          .map(
                            (v) => DropdownMenuEntry<ConflictBehavior>(
                              value: v,
                              label: _getConflictText(v, loc),
                            ),
                          )
                          .toList(),
                      onSelected: (val) {
                        if (val != null)
                          cubit.updateSettings(settings.copyWith(conflictBehavior: val));
                      },
                    ),
                  ),
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Performance',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  ListTile(
                    title: const Text('Performance preset'),
                    subtitle: Text(
                      settings.performancePreset == PerformancePreset.custom
                          ? 'Using the individual values set below.'
                          : '${settings.performancePreset.description}\n'
                                'Tuned automatically per ROM — the manual values below are ignored.',
                    ),
                    isThreeLine: settings.performancePreset != PerformancePreset.custom,
                    trailing: _buildDropdown<PerformancePreset>(
                      context: context,
                      initialSelection: settings.performancePreset,
                      width: 180,
                      entries: PerformancePreset.values
                          .map(
                            (preset) => DropdownMenuEntry<PerformancePreset>(
                              value: preset,
                              label: preset.label,
                            ),
                          )
                          .toList(),
                      onSelected: (val) {
                        if (val != null) {
                          cubit.updateSettings(settings.copyWith(performancePreset: val));
                        }
                      },
                    ),
                  ),
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      '3DS Options',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  _lockable(
                    locked: tuningLocked,
                    child: ListTile(
                      title: Text(loc.parallelism),
                      subtitle: Text(
                        '${effective.parallelism} ${loc.parallelismDesc.toLowerCase()}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: settings.parallelism > 1
                                ? () => cubit.updateSettings(
                                    settings.copyWith(parallelism: settings.parallelism - 1),
                                  )
                                : null,
                          ),
                          Text(
                            '${effective.parallelism}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: settings.parallelism < 16
                                ? () => cubit.updateSettings(
                                    settings.copyWith(parallelism: settings.parallelism + 1),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  SwitchListTile(
                    title: Text(loc.trimPadding),
                    subtitle: Text(loc.trimPaddingDesc),
                    value: settings.trimPadding,
                    onChanged: (val) => cubit.updateSettings(settings.copyWith(trimPadding: val)),
                  ),
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Patcher Options',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  SwitchListTile(
                    title: Text(loc.ignoreChecksum),
                    subtitle: Text(loc.ignoreChecksumSubtitle),
                    value: settings.ignoreChecksum,
                    onChanged: (val) =>
                        cubit.updateSettings(settings.copyWith(ignoreChecksum: val)),
                  ),
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'CHD Options',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  _lockable(
                    locked: tuningLocked,
                    child: ListTile(
                      title: const Text('Compression codecs'),
                      subtitle: Text(effective.chdCodecs),
                      trailing: _buildDropdown<String>(
                        context: context,
                        initialSelection: _chdCodecPresets.containsKey(effective.chdCodecs)
                            ? effective.chdCodecs
                            : _customCodecKey,
                        width: 220,
                        entries: [
                          ..._chdCodecPresets.entries.map(
                            (e) => DropdownMenuEntry(value: e.key, label: e.value),
                          ),
                          const DropdownMenuEntry(value: _customCodecKey, label: 'Custom…'),
                        ],
                        onSelected: (val) {
                          if (val == null) return;
                          if (val == _customCodecKey) {
                            _editChdCodecs(context, cubit, settings);
                          } else {
                            cubit.updateSettings(settings.copyWith(chdCodecs: val));
                          }
                        },
                      ),
                    ),
                  ),
                  _lockable(
                    locked: tuningLocked,
                    child: ListTile(
                      title: const Text('CPU threads (-np)'),
                      subtitle: Text(
                        effective.chdNumProcessors == 0
                            ? 'All available cores'
                            : '${effective.chdNumProcessors} thread(s)',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: settings.chdNumProcessors > 0
                                ? () => cubit.updateSettings(
                                    settings.copyWith(
                                      chdNumProcessors: settings.chdNumProcessors - 1,
                                    ),
                                  )
                                : null,
                          ),
                          Text(
                            effective.chdNumProcessors == 0
                                ? 'All'
                                : '${effective.chdNumProcessors}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: settings.chdNumProcessors < _maxCores
                                ? () => cubit.updateSettings(
                                    settings.copyWith(
                                      chdNumProcessors: settings.chdNumProcessors + 1,
                                    ),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _lockable(
                    locked: tuningLocked,
                    child: ListTile(
                      title: const Text('Hunk size (-hs)'),
                      subtitle: Text(
                        effective.chdHunkBytes == 0 ? 'Default' : '${effective.chdHunkBytes} bytes',
                      ),
                      trailing: const Icon(Icons.edit),
                      onTap: () => _editChdHunk(context, cubit, settings),
                    ),
                  ),
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'Switch Options',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  _lockable(
                    locked: tuningLocked,
                    child: ListTile(
                      title: const Text('Zstandard threads'),
                      subtitle: Text(
                        effective.nszThreadCount == 0
                            ? 'Default (cores - 2)'
                            : '${effective.nszThreadCount} thread(s)',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: settings.nszThreadCount > 0
                                ? () => cubit.updateSettings(
                                    settings.copyWith(nszThreadCount: settings.nszThreadCount - 1),
                                  )
                                : null,
                          ),
                          Text(
                            effective.nszThreadCount == 0 ? 'Auto' : '${effective.nszThreadCount}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: settings.nszThreadCount < _maxCores
                                ? () => cubit.updateSettings(
                                    settings.copyWith(nszThreadCount: settings.nszThreadCount + 1),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _lockable(
                    locked: tuningLocked,
                    child: ListTile(
                      title: const Text('I/O Chunk Size'),
                      subtitle: Text('${effective.nszChunkSizeMB} MB'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove),
                            onPressed: settings.nszChunkSizeMB > 1
                                ? () => cubit.updateSettings(
                                    settings.copyWith(nszChunkSizeMB: settings.nszChunkSizeMB - 1),
                                  )
                                : null,
                          ),
                          Text(
                            '${effective.nszChunkSizeMB}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: settings.nszChunkSizeMB < 64
                                ? () => cubit.updateSettings(
                                    settings.copyWith(nszChunkSizeMB: settings.nszChunkSizeMB + 1),
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  _lockable(
                    locked: tuningLocked,
                    child: ListTile(
                      title: const Text('Parallel NCA Compression'),
                      subtitle: const Text('Compress multiple NCAs in parallel using isolates'),
                      trailing: Switch(
                        value: effective.nszParallel,
                        onChanged: (val) =>
                            cubit.updateSettings(settings.copyWith(nszParallel: val)),
                      ),
                    ),
                  ),
                  ListTile(
                    title: const Text('NSZ Performance Benchmark'),
                    subtitle: const Text('Test and compare NSZ compression settings'),
                    trailing: const Icon(Icons.speed),
                    onTap: () => context.push('/nsz_benchmark'),
                  ),
                  const Divider(height: 32),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      'System & About',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                    ),
                  ),
                  if (Platform.isAndroid) const _StoragePermissionTile(),
                  ListTile(
                    title: const Text('Export App Logs'),
                    subtitle: const Text('Export logs to help debug issues'),
                    trailing: const Icon(Icons.download),
                    onTap: () async {
                      final path = await LoggerService.instance.getLogFilePath();
                      if (path != null && context.mounted) {
                        await FileService.shareFile(path);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Logs exported from $path'),
                              duration: const Duration(seconds: 5),
                            ),
                          );
                        }
                      } else {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('No logs available yet'),
                              duration: Duration(seconds: 5),
                            ),
                          );
                        }
                      }
                    },
                  ),
                  ListTile(
                    title: Text(loc.clearCache),
                    subtitle: Text(loc.clearCacheSubtitle),
                    trailing: const Icon(Icons.cleaning_services),
                    onTap: () async {
                      await FileService.clearCaches();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(loc.cacheCleared),
                            duration: const Duration(seconds: 5),
                          ),
                        );
                      }
                    },
                  ),
                  ListTile(
                    title: const Text('Credits & Acknowledgments'),
                    subtitle: const Text('View open source licenses'),
                    trailing: const Icon(Icons.info_outline),
                    onTap: () => _showCreditsDialog(context),
                  ),
                  const SizedBox(height: 32),
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Yasome',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        const SizedBox(height: 4),
                        FutureBuilder<PackageInfo>(
                          future: PackageInfo.fromPlatform(),
                          builder: (context, snapshot) {
                            if (snapshot.hasData) {
                              return Text('Version ${snapshot.data!.version}');
                            }
                            return const Text('Version ...');
                          },
                        ),
                        const SizedBox(height: 8),
                        IconButton(
                          onPressed: () =>
                              launchUrl(Uri.parse('https://github.com/Yasome/FinalRom')),
                          icon: FaIcon(FontAwesomeIcons.github),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Visually disables [child] (greys it out and swallows taps) when [locked]
  /// is true. Used for tuning controls that an active performance preset
  /// overrides.
  Widget _lockable({required bool locked, required Widget child}) {
    return IgnorePointer(
      ignoring: locked,
      child: Opacity(opacity: locked ? 0.4 : 1.0, child: child),
    );
  }

  Widget _buildDropdown<T>({
    required BuildContext context,
    required T initialSelection,
    required List<DropdownMenuEntry<T>> entries,
    required ValueChanged<T?> onSelected,
    double width = 180,
  }) {
    return DropdownMenu<T>(
      initialSelection: initialSelection,
      requestFocusOnTap: false,
      width: width,
      textStyle: Theme.of(context).textTheme.bodyMedium,
      onSelected: onSelected,
      dropdownMenuEntries: entries,
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(8.0)),
          borderSide: BorderSide.none,
        ),
        constraints: const BoxConstraints(maxHeight: 40),
      ),
    );
  }

  String _getConflictText(ConflictBehavior behavior, AppLocalizations loc) {
    switch (behavior) {
      case ConflictBehavior.ask:
        return loc.conflictAsk;
      case ConflictBehavior.overwrite:
        return loc.conflictOverwrite;
      case ConflictBehavior.autoRename:
        return loc.conflictRename;
    }
  }

  String _getThemeText(ThemeModeSetting theme, AppLocalizations loc) {
    switch (theme) {
      case ThemeModeSetting.system:
        return loc.themeSystem;
      case ThemeModeSetting.light:
        return loc.themeLight;
      case ThemeModeSetting.dark:
        return loc.themeDark;
    }
  }

  Future<void> _editChdCodecs(
    BuildContext context,
    SettingsCubit cubit,
    AppSettings settings,
  ) async {
    final loc = AppLocalizations.of(context)!;
    final result = await inputDialog(
      context,
      title: loc.chdCodecsTitle,
      initialValue: settings.chdCodecs,
      helperText: loc.chdCodecsHelper,
    );
    final trimmed = result?.trim();
    if (trimmed != null && trimmed.isNotEmpty) {
      cubit.updateSettings(settings.copyWith(chdCodecs: trimmed));
    }
  }

  Future<void> _editChdHunk(BuildContext context, SettingsCubit cubit, AppSettings settings) async {
    final loc = AppLocalizations.of(context)!;
    final result = await inputDialog(
      context,
      title: loc.chdHunkTitle,
      initialValue: settings.chdHunkBytes == 0 ? '' : '${settings.chdHunkBytes}',
      helperText: loc.chdHunkHelper,
      keyboardType: TextInputType.number,
    );
    if (result != null) {
      final parsed = int.tryParse(result.trim()) ?? 0;
      cubit.updateSettings(settings.copyWith(chdHunkBytes: parsed < 0 ? 0 : parsed));
    }
  }

  void _showCreditsDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Credits & Acknowledgments'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildCreditTile(
                context: ctx,
                title: 'MAME',
                subtitle: 'For the chdman utility used in CHD creation and extraction.',
                url: 'https://mamedev.org',
              ),
              _buildCreditTile(
                context: ctx,
                title: 'UniPatcher (btimofeev)',
                subtitle:
                    'The ROM patcher module (IPS, UPS, BPS, APS, PPF, EBP, DPS, xdelta '
                    'dispatch, checksums) is ported from UniPatcher.',
                url: 'https://github.com/btimofeev/UniPatcher',
              ),
              _buildCreditTile(
                context: ctx,
                title: 'NSZ (nicoboss)',
                subtitle:
                    'For the NSZ Python implementation used to design the Switch NSZ compressor.',
                url: 'https://github.com/nicoboss/nsz',
              ),
              _buildCreditTile(
                context: ctx,
                title: 'xdelta (jmacd)',
                subtitle: 'For the xdelta delta compression format and reference implementation.',
                url: 'https://github.com/jmacd/xdelta',
              ),
              _buildCreditTile(
                context: ctx,
                title: 'zstd (Meta Platforms)',
                subtitle: 'For the Zstandard compression library used to compress NSZ archives.',
                url: 'https://github.com/facebook/zstd',
              ),
              _buildCreditTile(
                context: ctx,
                title: 'b3DS (b1k & DemonKingSwarn)',
                subtitle:
                    'For the b3DSDecrypt/Encrypt scripts upon which the 3DS decryption and encryption logic is based.',
                url: 'https://github.com/b1k/b3DS\nhttps://github.com/DemonKingSwarn/b3DS',
              ),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _buildCreditTile({
    required BuildContext context,
    required String title,
    required String subtitle,
    required String url,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 4),
          ...url
              .split('\n')
              .map(
                (u) => InkWell(
                  onTap: () => launchUrl(Uri.parse(u)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2.0),
                    child: Text(
                      u,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// Settings tile (Android only) that requests the "All files access"
/// (`MANAGE_EXTERNAL_STORAGE`) permission the app needs to read and write ROMs
/// outside its own sandbox. The action button is disabled once the permission
/// is granted. Because the user grants it from a separate system settings
/// screen, the status is re-checked whenever the app returns to the foreground.
class _StoragePermissionTile extends StatefulWidget {
  const _StoragePermissionTile();

  @override
  State<_StoragePermissionTile> createState() => _StoragePermissionTileState();
}

class _StoragePermissionTileState extends State<_StoragePermissionTile>
    with WidgetsBindingObserver {
  bool _granted = false;
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshStatus();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The permission is toggled from the system settings screen, so re-check it
    // once the user comes back to the app.
    if (state == AppLifecycleState.resumed) {
      _refreshStatus();
    }
  }

  Future<void> _refreshStatus() async {
    final granted = await Permission.manageExternalStorage.isGranted;
    if (mounted) {
      setState(() {
        _granted = granted;
        _checking = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    await Permission.manageExternalStorage.request();
    await _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('All-files storage access'),
      subtitle: Text(
        _granted
            ? 'Granted — the app can read and write ROMs anywhere on the device.'
            : 'Required to read and write ROMs outside the app folder.',
      ),
      trailing: FilledButton.icon(
        // Disabled once granted (and while the initial status check runs).
        onPressed: _granted || _checking ? null : _requestPermission,
        icon: Icon(_granted ? Icons.check_circle : Icons.folder_special),
        label: Text(_granted ? 'Granted' : 'Grant'),
      ),
    );
  }
}
