import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:final_rom/l10n/app_localizations.dart';

import '../services/file_service.dart';
import '../services/nsz_worker.dart';
import '../services/switch_progress.dart';
import '../blocs/nsp_merge_bloc.dart';
import '../blocs/nsp_unmerge_bloc.dart';
import '../blocs/nsz_bloc.dart';
import '../blocs/queue_progress.dart';
import '../settings/settings_cubit.dart';
import '../settings/app_settings.dart';
import '../switch/nsz_input_profile.dart';
import 'home_screen.dart';
import 'android_file_picker.dart';
import 'app_spacing.dart';
import 'dart:io';

enum SwitchAction { merge, unmerge, compress, decompress }

class SwitchTab extends StatefulWidget {
  const SwitchTab({super.key});

  @override
  State<SwitchTab> createState() => _SwitchTabState();
}

class _SwitchTabState extends State<SwitchTab> {
  SwitchAction _action = SwitchAction.merge;

  // Merge state
  List<String> _mergeFiles = [];

  // Unmerge (split) queue
  List<String> _unmergeFiles = [];
  String? _unmergeKeysPath;

  // Compress queue
  List<String> _compressFiles = [];
  String? _keysPath;
  double _compressLevel = 18;

  // Decompress queue
  List<String> _decompressFiles = [];

  bool _hasExt(String path, List<String> exts) {
    final lower = path.toLowerCase();
    return exts.any((e) => lower.endsWith('.$e'));
  }

  /// Adds the [paths] that match [exts] to [current], keeping it unique, inside
  /// a setState. Used by both the Browse pickers and drag-drop.
  void _addToList(List<String> current, Iterable<String> paths, List<String> exts,
      void Function(List<String>) assign) {
    final valid = paths.where((path) => _hasExt(path, exts));
    if (valid.isEmpty) return;
    setState(() => assign(<String>{...current, ...valid}.toList()));
  }

  Future<List<String>> _pickMulti(BuildContext context, List<String> exts) async {
    if (Platform.isAndroid && context.mounted) {
      final picked = await AndroidFilePicker.pickFiles(context, allowedExtensions: exts);
      return picked ?? [];
    }
    return FileService.pickFiles(allowMultiple: true, allowedExtensions: exts);
  }

  @override
  Widget build(BuildContext context) {
    final loc = AppLocalizations.of(context)!;

    final isMergeRunning = context.watch<NspMergeBloc>().state is NspMergeRunning;
    final isUnmergeRunning = context.watch<NspUnmergeBloc>().state is NspUnmergeRunning;
    final isNszRunning = context.watch<NszBloc>().state is NszRunning;
    final isRunning = isMergeRunning || isUnmergeRunning || isNszRunning;

    return Column(
      children: [
        Padding(
          padding: AppSpacing.page,
          child: SegmentedButton<SwitchAction>(
            segments: [
              ButtonSegment(
                value: SwitchAction.merge,
                label: Text(loc.switchMergeTab),
                icon: const Icon(Icons.call_merge),
              ),
              ButtonSegment(
                value: SwitchAction.unmerge,
                label: Text(loc.switchSplitTab),
                icon: const Icon(Icons.call_split),
              ),
              ButtonSegment(
                value: SwitchAction.compress,
                label: Text(loc.switchCompressTab),
                icon: const Icon(Icons.compress),
              ),
              ButtonSegment(
                value: SwitchAction.decompress,
                label: Text(loc.switchDecompressTab),
                icon: const Icon(Icons.unfold_more),
              ),
            ],
            selected: {_action},
            onSelectionChanged: isRunning
                ? null
                : (newSelection) {
                    setState(() => _action = newSelection.first);
                  },
          ),
        ),
        Expanded(child: _buildCurrentView(context, loc, isRunning)),
      ],
    );
  }

  Widget _buildCurrentView(BuildContext context, AppLocalizations loc, bool isRunning) {
    switch (_action) {
      case SwitchAction.merge:
        return _buildMergeView(context, loc, isRunning);
      case SwitchAction.unmerge:
        return _buildUnmergeView(context, loc, isRunning);
      case SwitchAction.compress:
        return _buildCompressView(context, loc, isRunning);
      case SwitchAction.decompress:
        return _buildDecompressView(context, loc, isRunning);
    }
  }

  // --- Shared queue widgets ---

  /// The "Add files" + "Clear queue" buttons row, shared by every queue view.
  Widget _queueButtons({
    required AppLocalizations loc,
    required bool isRunning,
    required bool isEmpty,
    required VoidCallback onBrowse,
    required VoidCallback onClear,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        FilledButton.icon(
          icon: const Icon(Icons.add),
          label: Text(loc.btnBrowse),
          onPressed: isRunning ? null : onBrowse,
        ),
        OutlinedButton.icon(
          icon: const Icon(Icons.clear_all),
          label: Text(loc.btnClearQueue),
          onPressed: isRunning || isEmpty ? null : onClear,
        ),
      ],
    );
  }

  /// The scrollable list of queued files with per-row delete, shared by every
  /// queue view.
  Widget _queueList({
    required AppLocalizations loc,
    required List<String> files,
    required bool isRunning,
    required void Function(int index) onRemove,
  }) {
    return Expanded(
      child: Card(
        child: files.isEmpty
            ? Center(child: Text(loc.errNoFileSelected))
            : ListView.builder(
                itemCount: files.length,
                itemBuilder: (context, index) {
                  return ListTile(
                    key: ValueKey(files[index]),
                    leading: const Icon(Icons.file_present),
                    title: Text(p.basename(files[index])),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete),
                      onPressed: isRunning ? null : () => onRemove(index),
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// "File X of Y · status NN%" while a queue runs.
  String _runningLabel(
    AppLocalizations loc,
    SwitchProgress? progress,
    QueuePosition position,
    String fallbackStatus,
  ) {
    final status = progress?.message ?? fallbackStatus;
    if (position.isBatch) {
      return '${loc.queueFileProgress(position.currentIndex, position.total)} · $status';
    }
    return status;
  }

  /// Resolves the output directory for [inputFile] from the user's settings.
  Future<String> _outputDirFor(AppSettings settings, String inputFile) async {
    if (settings.outputLocation == OutputLocation.customDir) {
      return settings.customOutputDir ?? p.dirname(inputFile);
    } else if (settings.outputLocation == OutputLocation.appDocuments) {
      return FileService.getMobileOutputDirectory();
    }
    return p.dirname(inputFile);
  }

  /// Shows a snackbar summarizing how a compress/decompress queue ended.
  void _onNszBatchDone(BuildContext context, AppLocalizations loc, NszBatchDone state) {
    final total = state.results.length;
    if (total == 0) return;
    final timeStr = '${(state.duration.inMilliseconds / 1000).toStringAsFixed(2)}s';
    if (state.results.hasFailures) {
      final firstError = state.results.firstWhere((r) => !r.success).error;
      showErrorSnackBar(
        context,
        '${loc.queueFailuresSummary(state.results.failureCount, total)}'
        '${firstError != null ? ': $firstError' : ''}',
      );
    }
    final ok = state.results.successCount;
    if (ok > 0) {
      if (total == 1) {
        showSavedSnackBar(context, state.results.first.outputPath ?? '', trailing: timeStr);
      } else {
        showInfoSnackBar(context, '${loc.queueDoneSummary(ok, total)} ($timeStr)');
      }
    }
  }

  // --- MERGE VIEW ---
  Widget _buildMergeView(BuildContext context, AppLocalizations loc, bool isRunning) {
    return BlocConsumer<NspMergeBloc, NspMergeState>(
      listener: (context, state) {
        if (state is NspMergeSuccess) {
          final timeStr = '${(state.duration.inMilliseconds / 1000).toStringAsFixed(2)}s';
          showSavedSnackBar(context, state.outputPath, trailing: timeStr);
        } else if (state is NspMergeFailure) {
          showErrorSnackBar(context, state.error);
        }
      },
      builder: (context, state) {
        return DragDropTarget(
          hintText: loc.switchMergeHint,
          onFilesDropped: (paths) {
            final allowedFiles = paths.where((p) {
              final ext = p.toLowerCase();
              return ext.endsWith('.nsp') || ext.endsWith('.xci');
            }).toList();
            if (allowedFiles.isNotEmpty) {
              setState(() {
                _mergeFiles.addAll(allowedFiles);
                _mergeFiles = _mergeFiles.toSet().toList(); // unique
              });
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    FilledButton.icon(
                      icon: const Icon(Icons.add),
                      label: Text(loc.btnBrowse),
                      onPressed: isRunning
                          ? null
                          : () async {
                              final files = await _pickMulti(context, ['nsp', 'xci']);
                              setState(() {
                                _mergeFiles.addAll(
                                  files.where((p) {
                                    final ext = p.toLowerCase();
                                    return ext.endsWith('.nsp') || ext.endsWith('.xci');
                                  }),
                                );
                                _mergeFiles = _mergeFiles.toSet().toList();
                              });
                            },
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.clear_all),
                      label: Text(loc.btnClearQueue),
                      onPressed: isRunning || _mergeFiles.isEmpty
                          ? null
                          : () => setState(() => _mergeFiles.clear()),
                    ),
                  ],
                ),
                AppSpacing.gapMd,
                Expanded(
                  child: Card(
                    child: ReorderableListView.builder(
                      itemCount: _mergeFiles.length,
                      // ignore: deprecated_member_use
                      onReorder: isRunning
                          ? (o, n) {}
                          : (oldIndex, newIndex) {
                              setState(() {
                                if (oldIndex < newIndex) newIndex -= 1;
                                final item = _mergeFiles.removeAt(oldIndex);
                                _mergeFiles.insert(newIndex, item);
                              });
                            },
                      itemBuilder: (context, index) {
                        return ListTile(
                          key: ValueKey(_mergeFiles[index]),
                          leading: Icon(index == 0 ? Icons.star : Icons.file_present),
                          title: Text(p.basename(_mergeFiles[index])),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: isRunning
                                ? null
                                : () => setState(() => _mergeFiles.removeAt(index)),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                AppSpacing.gapMd,
                if (state is NspMergeRunning) ...[
                  LinearProgressIndicator(value: state.lastProgress?.fraction),
                  AppSpacing.gapSm,
                  Text(
                    state.lastProgress?.message ?? loc.statusMerging,
                    textAlign: TextAlign.center,
                  ),
                  AppSpacing.gapMd,
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (state is NspMergeRunning)
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(context).colorScheme.onError,
                        ),
                        onPressed: () => context.read<NspMergeBloc>().add(CancelNspMerge()),
                        child: Text(loc.btnCancel),
                      )
                    else
                      FilledButton(
                        onPressed: _mergeFiles.length < 2 ? null : () => _runMerge(context),
                        child: Text(loc.btnMerge),
                      ),
                  ],
                ),
                AppSpacing.gapXl,
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _runMerge(BuildContext context) async {
    final bloc = context.read<NspMergeBloc>();
    final settings = context.read<SettingsCubit>().state;
    final baseFile = _mergeFiles.first;
    final baseDir = await _outputDirFor(settings, baseFile);
    final baseName = p.basenameWithoutExtension(baseFile);
    final outputPath = p.join(baseDir, '$baseName-merged.nsp');
    bloc.add(StartNspMerge(inputNspPaths: _mergeFiles, outputPath: outputPath));
  }

  // --- UNMERGE (SPLIT) VIEW ---
  Widget _buildUnmergeView(BuildContext context, AppLocalizations loc, bool isRunning) {
    return BlocConsumer<NspUnmergeBloc, NspUnmergeState>(
      listener: (context, state) {
        if (state is NspUnmergeBatchDone) {
          _onUnmergeBatchDone(context, loc, state);
        }
      },
      builder: (context, state) {
        return DragDropTarget(
          hintText: loc.switchUnmergeHint,
          onFilesDropped: (paths) => _addToList(
              _unmergeFiles, paths, ['nsp'], (v) => _unmergeFiles = v),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _queueButtons(
                  loc: loc,
                  isRunning: isRunning,
                  isEmpty: _unmergeFiles.isEmpty,
                  onBrowse: () async {
                    final files = await _pickMulti(context, ['nsp']);
                    _addToList(_unmergeFiles, files, ['nsp'], (v) => _unmergeFiles = v);
                  },
                  onClear: () => setState(() => _unmergeFiles = []),
                ),
                AppSpacing.gapMd,
                _queueList(
                  loc: loc,
                  files: _unmergeFiles,
                  isRunning: isRunning,
                  onRemove: (i) => setState(() => _unmergeFiles.removeAt(i)),
                ),
                AppSpacing.gapMd,
                Card(
                  child: Padding(
                    padding: AppSpacing.card,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _unmergeKeysPath != null
                                ? p.basename(_unmergeKeysPath!)
                                : loc.switchKeysRequired,
                            style: TextStyle(
                              color: _unmergeKeysPath == null
                                  ? Theme.of(context).colorScheme.error
                                  : null,
                            ),
                          ),
                        ),
                        OutlinedButton(
                          onPressed: isRunning ? null : () => _browseKeys((k) => _unmergeKeysPath = k),
                          child: Text(loc.btnBrowseKeys),
                        ),
                      ],
                    ),
                  ),
                ),
                AppSpacing.gapMd,
                if (state is NspUnmergeRunning) ...[
                  LinearProgressIndicator(value: state.lastProgress?.fraction),
                  AppSpacing.gapSm,
                  Text(
                    _runningLabel(loc, state.lastProgress, state.position, loc.statusUnmerging),
                    textAlign: TextAlign.center,
                  ),
                  AppSpacing.gapMd,
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (state is NspUnmergeRunning)
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(context).colorScheme.onError,
                        ),
                        onPressed: () => context.read<NspUnmergeBloc>().add(CancelNspUnmerge()),
                        child: Text(loc.btnCancel),
                      )
                    else
                      FilledButton(
                        onPressed: (_unmergeFiles.isEmpty || _unmergeKeysPath == null)
                            ? null
                            : () => _runUnmerge(context),
                        child: Text(loc.btnUnmerge),
                      ),
                  ],
                ),
                AppSpacing.gapXl,
              ],
            ),
          ),
        );
      },
    );
  }

  void _onUnmergeBatchDone(
      BuildContext context, AppLocalizations loc, NspUnmergeBatchDone state) {
    final total = state.results.length;
    if (total == 0) return;
    if (state.results.hasFailures) {
      final firstError = state.results.firstWhere((r) => !r.success).error;
      showErrorSnackBar(
        context,
        '${loc.queueFailuresSummary(state.results.failureCount, total)}'
        '${firstError != null ? ': $firstError' : ''}',
      );
    }
    if (state.allOutputs.isNotEmpty) {
      final dir = p.dirname(state.allOutputs.first.outputPath);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(loc.unmergeSavedMessage(state.allOutputs.length, dir)),
          duration: const Duration(seconds: 5),
        ),
      );
      final missingCount = state.allOutputs.where((o) => o.missingNcaIds.isNotEmpty).length;
      if (missingCount > 0) {
        showWarningSnackBar(context, loc.unmergeMissingNcaWarning(missingCount));
      }
    }
  }

  Future<void> _runUnmerge(BuildContext context) async {
    if (_unmergeFiles.isEmpty || _unmergeKeysPath == null) return;
    final bloc = context.read<NspUnmergeBloc>();
    final settings = context.read<SettingsCubit>().state;
    final jobs = <UnmergeJob>[];
    for (final file in _unmergeFiles) {
      final dir = await _outputDirFor(settings, file);
      final name = p.basenameWithoutExtension(file);
      final outputDir = p.join(dir, '$name-unmerged');
      await Directory(outputDir).create(recursive: true);
      jobs.add(UnmergeJob(inputNspPath: file, outputDir: outputDir));
    }
    bloc.add(StartNspUnmerge(jobs: jobs, keysPath: _unmergeKeysPath!));
  }

  // --- COMPRESS VIEW ---
  Widget _buildCompressView(BuildContext context, AppLocalizations loc, bool isRunning) {
    return BlocConsumer<NszBloc, NszState>(
      listener: (context, state) {
        if (state is NszBatchDone) _onNszBatchDone(context, loc, state);
      },
      builder: (context, state) {
        return DragDropTarget(
          hintText: loc.switchCompressHint,
          onFilesDropped: (paths) => _addToList(
              _compressFiles, paths, ['nsp', 'xci'], (v) => _compressFiles = v),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _queueButtons(
                  loc: loc,
                  isRunning: isRunning,
                  isEmpty: _compressFiles.isEmpty,
                  onBrowse: () async {
                    final files = await _pickMulti(context, ['nsp', 'xci']);
                    _addToList(_compressFiles, files, ['nsp', 'xci'], (v) => _compressFiles = v);
                  },
                  onClear: () => setState(() => _compressFiles = []),
                ),
                AppSpacing.gapMd,
                _queueList(
                  loc: loc,
                  files: _compressFiles,
                  isRunning: isRunning,
                  onRemove: (i) => setState(() => _compressFiles.removeAt(i)),
                ),
                AppSpacing.gapMd,
                Card(
                  child: Padding(
                    padding: AppSpacing.card,
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _keysPath != null ? p.basename(_keysPath!) : loc.switchKeysRequired,
                                style: TextStyle(
                                  color: _keysPath == null
                                      ? Theme.of(context).colorScheme.error
                                      : null,
                                ),
                              ),
                            ),
                            OutlinedButton(
                              onPressed: isRunning ? null : () => _browseKeys((k) => _keysPath = k),
                              child: Text(loc.btnBrowseKeys),
                            ),
                          ],
                        ),
                        const Divider(),
                        Text('${loc.compressionLevel}: ${_compressLevel.toInt()}'),
                        Slider(
                          value: _compressLevel,
                          min: 1,
                          max: 22,
                          divisions: 21,
                          onChanged: isRunning ? null : (v) => setState(() => _compressLevel = v),
                        ),
                      ],
                    ),
                  ),
                ),
                AppSpacing.gapMd,
                if (state is NszRunning) ...[
                  LinearProgressIndicator(value: state.lastProgress?.fraction),
                  AppSpacing.gapSm,
                  Text(
                    _runningLabel(loc, state.lastProgress, state.position, loc.statusCompressing),
                    textAlign: TextAlign.center,
                  ),
                  AppSpacing.gapMd,
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (state is NszRunning)
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(context).colorScheme.onError,
                        ),
                        onPressed: () => context.read<NszBloc>().add(CancelNsz()),
                        child: Text(loc.btnCancel),
                      )
                    else
                      FilledButton(
                        onPressed: _compressFiles.isEmpty ? null : () => _runCompress(context),
                        child: Text(loc.btnCompress),
                      ),
                  ],
                ),
                AppSpacing.gapXl,
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _runCompress(BuildContext context) async {
    if (_compressFiles.isEmpty) return;
    if (_keysPath == null) {
      showErrorSnackBar(context, AppLocalizations.of(context)!.switchKeysRequired);
      return;
    }
    final bloc = context.read<NszBloc>();
    final settings = context.read<SettingsCubit>().state;
    final jobs = <NszJob>[];
    for (final file in _compressFiles) {
      final dir = await _outputDirFor(settings, file);
      final name = p.basenameWithoutExtension(file);
      final isXci = file.toLowerCase().endsWith('.xci');
      final out = p.join(dir, '$name.${isXci ? "xcz" : "nsz"}');
      // Adapt the preset to this archive's NCA layout (NSP only; an XCI's NCAs
      // live inside HFS0, so it is treated as dominant-NCA / single job).
      final profile = isXci ? null : await buildNspInputProfile(file);
      final tuning = settings.resolveTuning(
        input: profile,
        customCompressionLevel: _compressLevel.toInt(),
      );
      jobs.add(NszJob(
        action: NszAction.compress,
        inputPath: file,
        outputPath: out,
        keysPath: _keysPath,
        level: tuning.compressionLevel,
        threadCount: tuning.nszThreadCount,
        chunkSizeMB: tuning.nszChunkSizeMB,
        nszParallel: tuning.nszParallel,
        maxConcurrentNcas: tuning.nszMaxConcurrentNcas,
      ));
    }
    bloc.add(StartNsz(jobs: jobs));
  }

  // --- DECOMPRESS VIEW ---
  Widget _buildDecompressView(BuildContext context, AppLocalizations loc, bool isRunning) {
    return BlocConsumer<NszBloc, NszState>(
      listener: (context, state) {
        if (state is NszBatchDone) _onNszBatchDone(context, loc, state);
      },
      builder: (context, state) {
        return DragDropTarget(
          hintText: loc.switchDecompressHint,
          onFilesDropped: (paths) => _addToList(
              _decompressFiles, paths, ['nsz', 'xcz'], (v) => _decompressFiles = v),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _queueButtons(
                  loc: loc,
                  isRunning: isRunning,
                  isEmpty: _decompressFiles.isEmpty,
                  onBrowse: () async {
                    final files = await _pickMulti(context, ['nsz', 'xcz']);
                    _addToList(_decompressFiles, files, ['nsz', 'xcz'], (v) => _decompressFiles = v);
                  },
                  onClear: () => setState(() => _decompressFiles = []),
                ),
                AppSpacing.gapMd,
                _queueList(
                  loc: loc,
                  files: _decompressFiles,
                  isRunning: isRunning,
                  onRemove: (i) => setState(() => _decompressFiles.removeAt(i)),
                ),
                AppSpacing.gapMd,
                if (state is NszRunning) ...[
                  LinearProgressIndicator(value: state.lastProgress?.fraction),
                  AppSpacing.gapSm,
                  Text(
                    _runningLabel(loc, state.lastProgress, state.position, loc.statusDecompressing),
                    textAlign: TextAlign.center,
                  ),
                  AppSpacing.gapMd,
                ],
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    if (state is NszRunning)
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: Theme.of(context).colorScheme.error,
                          foregroundColor: Theme.of(context).colorScheme.onError,
                        ),
                        onPressed: () => context.read<NszBloc>().add(CancelNsz()),
                        child: Text(loc.btnCancel),
                      )
                    else
                      FilledButton(
                        onPressed: _decompressFiles.isEmpty ? null : () => _runDecompress(context),
                        child: Text(loc.btnDecompress),
                      ),
                  ],
                ),
                AppSpacing.gapXl,
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _runDecompress(BuildContext context) async {
    if (_decompressFiles.isEmpty) return;
    final bloc = context.read<NszBloc>();
    final settings = context.read<SettingsCubit>().state;
    final jobs = <NszJob>[];
    for (final file in _decompressFiles) {
      final dir = await _outputDirFor(settings, file);
      final name = p.basenameWithoutExtension(file);
      final isXcz = file.toLowerCase().endsWith('.xcz');
      final out = p.join(dir, '$name.${isXcz ? "xci" : "nsp"}');
      jobs.add(NszJob(
        action: NszAction.decompress,
        inputPath: file,
        outputPath: out,
        threadCount: settings.nszThreadCount,
        chunkSizeMB: settings.nszChunkSizeMB,
        nszParallel: settings.nszParallel,
      ));
    }
    bloc.add(StartNsz(jobs: jobs));
  }

  /// Shared keys-file picker. [assign] stores the chosen path into the right
  /// field; wrapped in setState.
  Future<void> _browseKeys(void Function(String) assign) async {
    String? keys;
    if (Platform.isAndroid && context.mounted) {
      keys = await AndroidFilePicker.pickFile(context);
    } else {
      keys = await FileService.pickAnyFile();
    }
    if (keys != null) setState(() => assign(keys!));
  }
}
