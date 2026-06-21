import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:final_rom/l10n/app_localizations.dart';

import '../settings/app_settings.dart';
import '../settings/settings_cubit.dart';
import '../services/file_service.dart';
import '../services/crypto_worker.dart';
import '../blocs/conversion_bloc.dart';
import '../blocs/batch_bloc.dart';
import 'home_screen.dart'; // For DragDropTarget
import 'android_file_picker.dart';
import 'app_spacing.dart';
import 'theme.dart';
import 'widgets/dialogs.dart';

enum ThreeDsMode { single, batch }

class ThreeDsTab extends StatefulWidget {
  const ThreeDsTab({super.key});

  @override
  State<ThreeDsTab> createState() => _ThreeDsTabState();
}

class _ThreeDsTabState extends State<ThreeDsTab> {
  ThreeDsMode _mode = ThreeDsMode.single;
  String? _selectedFile;
  String? _keysPath;
  bool _isPickingFiles = false;
  DateTime? _batchStartTime;

  @override
  void initState() {
    super.initState();
    _loadKeysPath();
  }

  Future<void> _loadKeysPath() async {
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _keysPath = prefs.getString('three_ds_keys_path');
      });
    }
  }

  Future<void> _saveKeysPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('three_ds_keys_path', path);
    if (mounted) {
      setState(() {
        _keysPath = path;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;
    final isConversionRunning = context.watch<ConversionBloc>().state is ConversionRunning;
    final isBatchRunning = context.watch<BatchBloc>().state is BatchRunning;
    final isRunning = isConversionRunning || isBatchRunning;

    return DragDropTarget(
      hintText: _mode == ThreeDsMode.single ? loc.dragDropHintSingle : loc.dragDropHintBatch,
      onFilesDropped: (paths) {
        if (_mode == ThreeDsMode.single) {
          final dsFile = paths.firstWhere(
            (path) => p.extension(path).toLowerCase() == '.3ds',
            orElse: () => '',
          );
          if (dsFile.isNotEmpty) {
            setState(() => _selectedFile = dsFile);
          } else {
            showErrorSnackBar(context, loc.dragDropOnly3ds);
          }
        } else {
          final dsFiles = paths.where((path) => p.extension(path).toLowerCase() == '.3ds').toList();
          if (dsFiles.isNotEmpty) {
            context.read<BatchBloc>().add(AddFilesToBatch(dsFiles));
          } else {
            showErrorSnackBar(context, loc.dragDropOnly3ds);
          }
        }
      },
      child: Column(
        children: [
          Padding(
            padding: AppSpacing.page,
            child: SegmentedButton<ThreeDsMode>(
              segments: [
                ButtonSegment(
                  value: ThreeDsMode.single,
                  label: Text(loc.tabSingleFile),
                  icon: const Icon(Icons.insert_drive_file),
                ),
                ButtonSegment(
                  value: ThreeDsMode.batch,
                  label: Text(loc.tabBatchMode),
                  icon: const Icon(Icons.library_books),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: isRunning
                  ? null
                  : (newSelection) {
                      setState(() => _mode = newSelection.first);
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _keysPath != null
                            ? p.basename(_keysPath!)
                            : loc.keysRequired3ds,
                        style: TextStyle(
                          color: _keysPath == null
                              ? Theme.of(context).colorScheme.error
                              : null,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: isRunning
                          ? null
                          : () async {
                              String? keys;
                              if (Platform.isAndroid && context.mounted) {
                                keys = await AndroidFilePicker.pickFile(context);
                              } else {
                                keys = await FileService.pickAnyFile();
                              }
                              if (keys != null) {
                                await _saveKeysPath(keys);
                              }
                            },
                      child: Text(loc.btnBrowseKeys),
                    ),
                  ],
                ),
              ),
            ),
          ),
          AppSpacing.gapMd,
          Expanded(
            child: _mode == ThreeDsMode.single
                ? _buildSingleFileView(context, loc, isConversionRunning)
                : _buildBatchView(context, loc, isBatchRunning),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleFileView(BuildContext context, AppLocalizations loc, bool isRunning) {
    return BlocConsumer<ConversionBloc, ConversionState>(
      listener: (context, state) {
        if (state is ConversionSuccess) {
          if (state.alreadyDecrypted) {
            showInfoSnackBar(context, loc.alreadyDecryptedMessage);
          } else {
            final timeStr = '${(state.duration.inMilliseconds / 1000).toStringAsFixed(2)}s';
            showSavedSnackBar(context, state.outputPath, trailing: timeStr);
          }
        } else if (state is ConversionFailure) {
          showErrorSnackBar(context, state.error);
        }
      },
      builder: (context, state) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        child: Padding(
                          padding: AppSpacing.card,
                          child: Column(
                            children: [
                              Text(
                                _selectedFile != null
                                    ? p.basename(_selectedFile!)
                                    : loc.errNoFileSelected,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              AppSpacing.gapMd,
                              OutlinedButton.icon(
                                icon: _isPickingFiles
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      )
                                    : const Icon(Icons.file_open),
                                label: Text(loc.btnBrowse),
                                onPressed: (isRunning || _isPickingFiles)
                                    ? null
                                    : () async {
                                        setState(() => _isPickingFiles = true);
                                        try {
                                          List<String> files = [];
                                          if (Platform.isAndroid && context.mounted) {
                                            final picked = await AndroidFilePicker.pickFile(
                                              context,
                                              allowedExtensions: ['3ds'],
                                            );
                                            if (picked != null) files.add(picked);
                                          } else {
                                            files = await FileService.pickFiles(
                                              allowMultiple: false,
                                            );
                                          }
                                          if (files.isNotEmpty && context.mounted) {
                                            setState(() => _selectedFile = files.first);
                                          }
                                        } finally {
                                          if (mounted) setState(() => _isPickingFiles = false);
                                        }
                                      },
                              ),
                            ],
                          ),
                        ),
                      ),
                      AppSpacing.gapLg,
                      if (state is ConversionRunning) ...[
                        LinearProgressIndicator(value: state.lastProgress?.fraction),
                        AppSpacing.gapSm,
                        Text(
                          state.lastProgress?.message ?? loc.statusIdle,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        AppSpacing.gapLg,
                      ] else if (state is ConversionSuccess) ...[
                        if (state.alreadyDecrypted)
                          Text(
                            loc.alreadyDecryptedMessage,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: context.semantic.success),
                          )
                        else ...[
                          Text(
                            '${loc.statusDone} in ${(state.duration.inMilliseconds / 1000).toStringAsFixed(2)}s',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: context.semantic.success),
                          ),
                          if (state.trimMessage != null)
                            Text(state.trimMessage!, textAlign: TextAlign.center),
                        ],
                        AppSpacing.gapLg,
                      ],
                    ],
                  ),
                ),
              ),
              AppSpacing.gapMd,
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (isRunning)
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      ),
                      onPressed: () => context.read<ConversionBloc>().add(CancelConversion()),
                      child: Text(loc.btnCancel),
                    )
                  else ...[
                    FilledButton(
                      onPressed: (_selectedFile == null || _keysPath == null)
                          ? null
                          : () => _runAction(context, CryptoAction.decrypt),
                      child: Text(loc.btnDecrypt),
                    ),
                    FilledButton(
                      onPressed: (_selectedFile == null || _keysPath == null)
                          ? null
                          : () => _runAction(context, CryptoAction.encrypt),
                      child: Text(loc.btnEncrypt),
                    ),
                  ],
                ],
              ),
              AppSpacing.gapXl,
            ],
          ),
        );
      },
    );
  }

  Widget _buildCumulativeBatchProgress(BuildContext context, List<BatchItem> items) {
    final theme = Theme.of(context);
    if (items.isEmpty) return const SizedBox.shrink();

    final total = items.length;
    final completed = items
        .where((i) => i.status == BatchItemStatus.success || i.status == BatchItemStatus.failure)
        .length;

    // Calculate cumulative fraction
    double sum = 0.0;
    for (final item in items) {
      if (item.status == BatchItemStatus.success || item.status == BatchItemStatus.failure) {
        sum += 1.0;
      } else if (item.status == BatchItemStatus.running) {
        sum += item.lastProgress?.fraction ?? 0.0;
      }
    }
    final fraction = sum / total;
    final percent = (fraction * 100).toStringAsFixed(1);

    String etaText = '';
    if (_batchStartTime != null) {
      final elapsedMs = DateTime.now().difference(_batchStartTime!).inMilliseconds;
      final elapsedSec = elapsedMs / 1000.0;
      if (elapsedSec > 0.5 && fraction > 0.01) {
        final totalEstSec = elapsedSec / fraction;
        final remainingSec = totalEstSec - elapsedSec;
        if (remainingSec > 0.5) {
          etaText = ' • ${remainingSec.toStringAsFixed(0)}s remaining';
        }
      }
    }

    return Card(
      elevation: 0,
      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.25),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.15), width: 1),
      ),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Overall Batch Progress',
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                Text(
                  'File $completed of $total$etaText',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: fraction),
            AppSpacing.gapSm,
            Text(
              'Overall Progress: $percent%',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBatchView(BuildContext context, AppLocalizations loc, bool isRunning) {
    return BlocConsumer<BatchBloc, BatchState>(
      listener: (context, state) {
        if (state is BatchRunning) {
          _batchStartTime ??= DateTime.now();
        } else if (state is BatchFinished) {
          _batchStartTime = null;
          int success = state.items.where((i) => i.status == BatchItemStatus.success).length;
          int failed = state.items.where((i) => i.status == BatchItemStatus.failure).length;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                loc.batchSummary(
                  success,
                  failed,
                  (state.totalDuration.inMilliseconds / 1000).toStringAsFixed(2),
                ),
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        } else if (state is BatchIdle) {
          _batchStartTime = null;
        }
      },
      builder: (context, state) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  FilledButton.icon(
                    icon: _isPickingFiles
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Theme.of(context).colorScheme.onPrimary,
                            ),
                          )
                        : const Icon(Icons.file_open),
                    label: Text(loc.btnBrowse),
                    onPressed: (isRunning || _isPickingFiles)
                        ? null
                        : () async {
                            setState(() => _isPickingFiles = true);
                            try {
                              final List<String> files = [];
                              if (Platform.isAndroid && context.mounted) {
                                final picked = await AndroidFilePicker.pickFiles(
                                  context,
                                  allowedExtensions: ['3ds'],
                                );
                                if (picked != null) files.addAll(picked);
                              } else {
                                final result = await FileService.pickFiles(allowMultiple: true);
                                files.addAll(result);
                              }
                              if (files.isNotEmpty && context.mounted) {
                                context.read<BatchBloc>().add(AddFilesToBatch(files));
                              }
                            } finally {
                              if (mounted) setState(() => _isPickingFiles = false);
                            }
                          },
                  ),
                  if (FileService.isDesktop)
                    FilledButton.icon(
                      icon: _isPickingFiles
                          ? SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Theme.of(context).colorScheme.onPrimary,
                              ),
                            )
                          : const Icon(Icons.folder),
                      label: Text(loc.btnBrowseFolder),
                      onPressed: (isRunning || _isPickingFiles)
                          ? null
                          : () async {
                              setState(() => _isPickingFiles = true);
                              try {
                                final files = await FileService.pickFolderAndScan();
                                if (files.isNotEmpty && context.mounted) {
                                  context.read<BatchBloc>().add(AddFilesToBatch(files));
                                }
                              } finally {
                                if (mounted) setState(() => _isPickingFiles = false);
                              }
                            },
                    ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.clear_all),
                    label: Text(loc.btnClearQueue),
                    onPressed: isRunning || state.items.isEmpty
                        ? null
                        : () => context.read<BatchBloc>().add(ClearBatchQueue()),
                  ),
                ],
              ),
            ),
            if (isRunning) _buildCumulativeBatchProgress(context, state.items),
            Expanded(
              child: ListView.builder(
                itemCount: state.items.length,
                itemBuilder: (context, index) {
                  final item = state.items[index];
                  Widget trailing;
                  if (item.status == BatchItemStatus.success) {
                    trailing = Icon(Icons.check_circle, color: context.semantic.success);
                  } else if (item.status == BatchItemStatus.failure) {
                    trailing = Tooltip(
                      message: item.errorMessage ?? loc.statusError,
                      child: Icon(Icons.error, color: Theme.of(context).colorScheme.error),
                    );
                  } else if (item.status == BatchItemStatus.running) {
                    trailing = SizedBox(
                      width: 100,
                      child: LinearProgressIndicator(value: item.lastProgress?.fraction),
                    );
                  } else {
                    trailing = IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: isRunning
                          ? null
                          : () {
                              context.read<BatchBloc>().add(RemoveFileFromBatch(item.path));
                            },
                    );
                  }

                  return ListTile(
                    title: Text(p.basename(item.path)),
                    subtitle: Builder(
                      builder: (_) {
                        if (item.status == BatchItemStatus.failure) {
                          return Text(
                            item.errorMessage ?? loc.statusError,
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          );
                        }
                        if (item.status == BatchItemStatus.running) {
                          return Text(item.lastProgress?.message ?? '');
                        }
                        if (item.status == BatchItemStatus.success && item.alreadyDecrypted) {
                          return Text(
                            loc.alreadyDecryptedMessage,
                            style: TextStyle(color: context.semantic.success),
                          );
                        }
                        final parts = <String>[];
                        if (item.trimMessage != null) parts.add(item.trimMessage!);
                        if (item.status == BatchItemStatus.success && item.duration != null) {
                          parts.add(
                            'Done in ${(item.duration!.inMilliseconds / 1000).toStringAsFixed(2)}s',
                          );
                        }
                        if (parts.isNotEmpty) return Text(parts.join(' - '));
                        return const SizedBox.shrink();
                      },
                    ),
                    trailing: trailing,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 32.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  if (isRunning)
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      ),
                      onPressed: () => context.read<BatchBloc>().add(CancelBatch()),
                      child: Text(loc.btnCancel),
                    )
                  else ...[
                    FilledButton(
                      onPressed: (state.items.isEmpty || _keysPath == null)
                          ? null
                          : () => _runBatchAction(context, CryptoAction.decrypt),
                      child: Text(loc.btnDecrypt),
                    ),
                    FilledButton(
                      onPressed: (state.items.isEmpty || _keysPath == null)
                          ? null
                          : () => _runBatchAction(context, CryptoAction.encrypt),
                      child: Text(loc.btnEncrypt),
                    ),
                  ],
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _runAction(BuildContext context, CryptoAction action) async {
    final settings = context.read<SettingsCubit>().state;
    final loc = AppLocalizations.of(context)!;

    if (_selectedFile == null) return;
    if (_keysPath == null || _keysPath!.isEmpty) {
      showErrorSnackBar(context, loc.keysRequired3ds);
      return;
    }

    final result = await _resolveOutputPath(context, _selectedFile!, action, settings, loc);
    if (result == null) return; // cancelled

    if (context.mounted) {
      context.read<ConversionBloc>().add(
        StartConversion(
          action: action,
          inputPath: _selectedFile!,
          outputPath: result.path,
          keysPath: _keysPath!,
          inPlace: result.inPlace,
          trim: settings.trimPadding,
        ),
      );
    }
  }

  Future<void> _runBatchAction(BuildContext context, CryptoAction action) async {
    final settings = context.read<SettingsCubit>().state;
    final loc = AppLocalizations.of(context)!;

    if (_keysPath == null || _keysPath!.isEmpty) {
      showErrorSnackBar(context, loc.keysRequired3ds);
      return;
    }

    if (settings.inPlace && FileService.supportsInPlace) {
      final confirm = await confirmDialog(
        context,
        title: loc.confirmOverwriteTitle,
        content: loc.confirmOverwriteContent,
        destructive: true,
      );
      if (!confirm) return;
      if (context.mounted) {
        context.read<BatchBloc>().add(
          StartBatch(
            action: action,
            keysPath: _keysPath!,
            inPlace: true,
            trim: settings.trimPadding,
            parallelism: settings.resolveTuning().parallelism,
          ),
        );
      }
      return;
    }

    String? outputFolder;
    if (settings.outputLocation == OutputLocation.customDir) {
      outputFolder = settings.customOutputDir;
      if (outputFolder == null) {
        if (Platform.isAndroid && context.mounted) {
          outputFolder = await AndroidFilePicker.pickDirectory(context);
        } else {
          outputFolder = await FileService.pickOutputFolder();
        }
        if (outputFolder == null) return;
      }
    } else if (settings.outputLocation == OutputLocation.appDocuments) {
      outputFolder = await FileService.getMobileOutputDirectory();
    }

    if (context.mounted) {
      context.read<BatchBloc>().add(
        StartBatch(
          action: action,
          outputFolder: outputFolder,
          keysPath: _keysPath!,
          inPlace: false,
          trim: settings.trimPadding,
          parallelism: settings.resolveTuning().parallelism,
        ),
      );
    }
  }
}

class _ResolvedPath {
  final String? path;
  final bool inPlace;
  _ResolvedPath(this.path, this.inPlace);
}

Future<_ResolvedPath?> _resolveOutputPath(
  BuildContext context,
  String inputPath,
  CryptoAction action,
  AppSettings settings,
  AppLocalizations loc,
) async {
  if (settings.inPlace && FileService.supportsInPlace) {
    final confirm = await confirmDialog(
      context,
      title: loc.confirmOverwriteTitle,
      content: loc.confirmOverwriteContent,
      destructive: true,
    );
    if (confirm) return _ResolvedPath(null, true);
    return null;
  }

  String baseFolder = p.dirname(inputPath);
  if (settings.outputLocation == OutputLocation.customDir) {
    baseFolder = settings.customOutputDir ?? baseFolder;
  } else if (settings.outputLocation == OutputLocation.appDocuments) {
    baseFolder = await FileService.getMobileOutputDirectory();
  }

  final baseName = p.basenameWithoutExtension(inputPath);
  final suffix = action == CryptoAction.decrypt ? '-decrypted' : '-encrypted';
  String finalPath = p.join(baseFolder, '$baseName$suffix.3ds');

  if (await File(finalPath).exists()) {
    if (settings.conflictBehavior == ConflictBehavior.ask) {
      if (!context.mounted) return null;
      final choice = await conflictChoiceDialog(context, p.basename(finalPath));
      if (choice == null) return null;
      if (choice == ConflictBehavior.autoRename) {
        finalPath = await FileService.generateUniqueOutputPath(
          baseFolder,
          '$baseName$suffix',
          '.3ds',
        );
      }
    } else if (settings.conflictBehavior == ConflictBehavior.autoRename) {
      finalPath = await FileService.generateUniqueOutputPath(
        baseFolder,
        '$baseName$suffix',
        '.3ds',
      );
    }
  }

  return _ResolvedPath(finalPath, false);
}
