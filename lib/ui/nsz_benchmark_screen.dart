import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path/path.dart' as p;
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'home_screen.dart';
import 'theme.dart';

import '../settings/settings_cubit.dart';
import '../services/file_service.dart';
import '../switch/keys.dart';
import '../switch/nsz_archive.dart';
import 'android_file_picker.dart';

class _BenchmarkParams {
  final String inputPath;
  final String outputPath;
  final String keysPath;
  final int threadCount;
  final int chunkSizeMB;
  final bool nszParallel;
  final String tempDirPath;
  final SendPort sendPort;

  _BenchmarkParams({
    required this.inputPath,
    required this.outputPath,
    required this.keysPath,
    required this.threadCount,
    required this.chunkSizeMB,
    required this.nszParallel,
    required this.tempDirPath,
    required this.sendPort,
  });
}

void _runBenchmarkIsolate(_BenchmarkParams params) async {
  try {
    final keys = SwitchKeys.parse(await File(params.keysPath).readAsString());
    await NszArchive.compress(
      inputNspPath: params.inputPath,
      outputPath: params.outputPath,
      keys: keys,
      level: 18,
      threadCount: params.threadCount,
      chunkSizeMB: params.chunkSizeMB,
      nszParallel: params.nszParallel,
      tempDirPath: params.tempDirPath,
      onProgress: (msg, frac) {
        params.sendPort.send({'type': 'progress', 'message': msg, 'fraction': frac});
      },
    );
    params.sendPort.send({'type': 'success'});
  } catch (e) {
    params.sendPort.send({'type': 'error', 'error': e.toString()});
  }
}

class NszBenchmarkScreen extends StatefulWidget {
  const NszBenchmarkScreen({super.key});

  @override
  State<NszBenchmarkScreen> createState() => _NszBenchmarkScreenState();
}

class _NszBenchmarkScreenState extends State<NszBenchmarkScreen> {
  final _scrollController = ScrollController();

  String _inputPath = '';
  String _keysPath = '';
  int _threadCount = 0;
  int _chunkSizeMB = 2;
  bool _nszParallel = true;

  bool _isRunning = false;
  double _progress = 0.0;
  String _statusMessage = 'Idle';
  final List<String> _logs = [];

  // Results
  Duration? _elapsed;
  int? _inputSize;
  int? _outputSize;
  double _speedMBs = 0.0;
  String _etaText = '';
  List<_BenchmarkResult> _history = [];

  Isolate? _isolate;
  ReceivePort? _receivePort;
  String? _tempDirPath;
  String? _outputPath;
  Stopwatch? _stopwatch;

  @override
  void initState() {
    super.initState();
    // Load values from Settings
    final settings = context.read<SettingsCubit>().state;
    _threadCount = settings.nszThreadCount;
    _chunkSizeMB = settings.nszChunkSizeMB;
    _nszParallel = settings.nszParallel;

    _loadPersistedPaths();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('nsz_benchmark_history') ?? [];
    setState(() {
      _history = list.map((item) {
        try {
          return _BenchmarkResult.fromJson(jsonDecode(item) as Map<String, dynamic>);
        } catch (_) {
          return null;
        }
      }).whereType<_BenchmarkResult>().toList();
    });
  }

  Future<void> _saveToHistory(_BenchmarkResult result) async {
    final prefs = await SharedPreferences.getInstance();
    _history.insert(0, result);
    if (_history.length > 5) {
      _history = _history.sublist(0, 5);
    }
    final list = _history.map((item) => jsonEncode(item.toJson())).toList();
    await prefs.setStringList('nsz_benchmark_history', list);
    setState(() {});
  }

  Future<void> _clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('nsz_benchmark_history');
    setState(() {
      _history.clear();
    });
  }

  Future<void> _loadPersistedPaths() async {
    final prefs = await SharedPreferences.getInstance();
    final savedNsp = prefs.getString('nsz_benchmark_nsp_path') ?? '';
    final savedKeys = prefs.getString('nsz_benchmark_keys_path') ?? '';

    setState(() {
      if (savedNsp.isNotEmpty && File(savedNsp).existsSync()) {
        _inputPath = savedNsp;
      } else {
        _inputPath = '';
      }

      if (savedKeys.isNotEmpty && File(savedKeys).existsSync()) {
        _keysPath = savedKeys;
      } else {
        _keysPath = '';
      }
    });
  }

  Future<void> _persistInputPath(String path) async {
    setState(() => _inputPath = path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nsz_benchmark_nsp_path', path);
  }

  Future<void> _persistKeysPath(String path) async {
    setState(() => _keysPath = path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('nsz_benchmark_keys_path', path);
  }

  // The benchmark is a pure sandbox: it seeds its params from Settings in
  // initState but never writes back, so experimenting here can't overwrite the
  // saved Switch settings (which a performance preset may have locked).
  void _updateThreadCount(int val) {
    setState(() => _threadCount = val);
  }

  void _updateChunkSize(int val) {
    setState(() => _chunkSizeMB = val);
  }

  void _updateNszParallel(bool val) {
    setState(() => _nszParallel = val);
  }

  @override
  void dispose() {
    _cleanup();
    _scrollController.dispose();
    super.dispose();
  }

  void _log(String message) {
    setState(() {
      _logs.add('[${DateTime.now().toLocal().toString().split(' ').last.substring(0, 8)}] $message');
    });
    // Auto-scroll to bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _startBenchmark() async {
    if (_inputPath.isEmpty || _keysPath.isEmpty) {
      final scheme = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: SelectableText(
            'Please select both input file and keys file.',
            style: TextStyle(color: scheme.onError),
          ),
          backgroundColor: scheme.error,
          duration: const Duration(seconds: 10),
        ),
      );
      return;
    }

    final inSize = File(_inputPath).lengthSync();
    setState(() {
      _isRunning = true;
      _progress = 0.0;
      _statusMessage = 'Initializing...';
      _logs.clear();
      _elapsed = null;
      _inputSize = inSize;
      _outputSize = null;
      _speedMBs = 0.0;
      _etaText = '';
    });

    _log('Starting NSZ benchmark run...');
    _log('Input File: $_inputPath');
    _log('Keys File: $_keysPath');
    _log('Threads: ${_threadCount == 0 ? 'Auto' : _threadCount}');
    _log('Chunk Size: $_chunkSizeMB MB');
    _log('Parallel NCA: $_nszParallel');

    _tempDirPath = await FileService.createScratchDir();
    final inputDir = p.dirname(_inputPath);
    _outputPath = p.join(inputDir, 'benchmark_temp_${DateTime.now().millisecondsSinceEpoch}.nsz');

    _receivePort = ReceivePort();
    _stopwatch = Stopwatch()..start();

    _receivePort!.listen((message) {
      if (message is Map) {
        final type = message['type'];
        if (type == 'progress') {
          final msg = message['message'] as String;
          final frac = message['fraction'] as double;
          
          double speed = 0.0;
          String eta = '';
          if (_stopwatch != null && _inputSize != null && frac > 0.01) {
            final elapsedSec = _stopwatch!.elapsedMilliseconds / 1000.0;
            final processed = _inputSize! * frac;
            if (elapsedSec > 0.5) {
              final bytesPerSec = processed / elapsedSec;
              speed = bytesPerSec / (1024 * 1024);
              final remaining = _inputSize! * (1.0 - frac);
              final remainingSec = remaining / bytesPerSec;
              if (remainingSec > 0) {
                eta = '${remainingSec.toStringAsFixed(0)}s remaining';
              }
            }
          }

          setState(() {
            _progress = frac;
            _statusMessage = msg;
            _speedMBs = speed;
            _etaText = eta;
          });
          _log('$msg (${(frac * 100).toStringAsFixed(1)}%)');
        } else if (type == 'success') {
          _onSuccess();
        } else if (type == 'error') {
          _onError(message['error'] as String);
        }
      }
    });

    try {
      _isolate = await Isolate.spawn(
        _runBenchmarkIsolate,
        _BenchmarkParams(
          inputPath: _inputPath,
          outputPath: _outputPath!,
          keysPath: _keysPath,
          threadCount: _threadCount,
          chunkSizeMB: _chunkSizeMB,
          nszParallel: _nszParallel,
          tempDirPath: _tempDirPath!,
          sendPort: _receivePort!.sendPort,
        ),
      );
    } catch (e) {
      _onError(e.toString());
    }
  }

  void _onSuccess() {
    _stopwatch?.stop();
    final elapsed = _stopwatch?.elapsed ?? Duration.zero;

    final inSize = File(_inputPath).lengthSync();
    final outSize = File(_outputPath!).lengthSync();

    setState(() {
      _isRunning = false;
      _progress = 1.0;
      _statusMessage = 'Completed successfully!';
      _elapsed = elapsed;
      _inputSize = inSize;
      _outputSize = outSize;
    });

    _log('Benchmark complete!');
    _log('Time taken: ${(elapsed.inMilliseconds / 1000).toStringAsFixed(2)} seconds');
    _log('Original size: ${(inSize / 1024 / 1024).toStringAsFixed(2)} MB');
    _log('Compressed size: ${(outSize / 1024 / 1024).toStringAsFixed(2)} MB');

    // Clean up temporary benchmark output file
    try {
      final file = File(_outputPath!);
      if (file.existsSync()) {
        file.deleteSync();
        _log('Cleaned up temporary output file.');
      }
    } catch (e) {
      _log('Failed to delete temporary output file: $e');
    }

    _cleanupIsolate();

    _saveToHistory(_BenchmarkResult(
      timestamp: DateTime.now(),
      threadCount: _threadCount,
      chunkSizeMB: _chunkSizeMB,
      nszParallel: _nszParallel,
      durationSeconds: elapsed.inMilliseconds / 1000.0,
      savingsPercent: (1 - outSize / inSize) * 100,
    ));
  }

  void _onError(String error) {
    _stopwatch?.stop();
    setState(() {
      _isRunning = false;
      _statusMessage = 'Failed';
    });
    _log('ERROR: $error');
    _cleanup();
  }

  void _cancelBenchmark() {
    _stopwatch?.stop();
    setState(() {
      _isRunning = false;
      _statusMessage = 'Cancelled';
    });
    _log('Benchmark run cancelled by user.');
    _cleanup();
  }

  void _cleanupIsolate() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
  }

  void _cleanup() {
    _cleanupIsolate();
    final tempDirPath = _tempDirPath;
    _tempDirPath = null;
    if (tempDirPath != null) {
      FileService.deleteScratchDir(tempDirPath);
    }
    final outPath = _outputPath;
    _outputPath = null;
    if (outPath != null) {
      try {
        final file = File(outPath);
        if (file.existsSync()) {
          file.deleteSync();
        }
      } catch (_) {}
    }
  }

  void _handleDroppedFiles(List<String> paths) {
    if (_isRunning) return;
    for (final path in paths) {
      final ext = p.extension(path).toLowerCase();
      final name = p.basename(path).toLowerCase();
      if (ext == '.nsp') {
        _persistInputPath(path);
        _log('NSP file set via drag & drop: $path');
      } else if (ext == '.keys' || ext == '.key' || name == 'prod.keys') {
        _persistKeysPath(path);
        _log('Keys file set via drag & drop: $path');
      } else {
        _log('Unsupported file dropped: $name');
      }
    }
  }

  Future<void> _copyMarkdownReport() async {
    if (_elapsed == null || _inputSize == null || _outputSize == null) return;

    final inMB = _inputSize! / (1024 * 1024);
    final outMB = _outputSize! / (1024 * 1024);
    final savings = (1 - _outputSize! / _inputSize!) * 100;
    final speed = inMB / (_elapsed!.inMilliseconds / 1000.0);

    final report = '''
# NSZ Performance Benchmark Report
Generated on: ${DateTime.now().toLocal().toString().split('.').first}

## System Specification
- **OS**: ${Platform.operatingSystem} (${Platform.operatingSystemVersion})
- **CPU Cores**: ${Platform.numberOfProcessors}

## Parameters Configuration
- **Zstd Thread Count**: ${_threadCount == 0 ? 'Auto (cores - 2)' : '$_threadCount'}
- **I/O Chunk Size**: $_chunkSizeMB MB
- **Parallel NCA**: $_nszParallel

## Benchmark Performance
- **Total Duration**: ${(_elapsed!.inMilliseconds / 1000).toStringAsFixed(2)} seconds
- **Original Size**: ${inMB.toStringAsFixed(2)} MB
- **Compressed Size**: ${outMB.toStringAsFixed(2)} MB
- **Space Savings**: ${savings.toStringAsFixed(2)}%
- **Average Compression Speed**: ${speed.toStringAsFixed(2)} MB/s
''';

    await Clipboard.setData(ClipboardData(text: report.trim()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Benchmark report copied to clipboard'),
          duration: Duration(seconds: 5),
        ),
      );
    }
  }

  Widget _buildSystemSpecsHeader(BuildContext context) {
    final theme = Theme.of(context);
    final os = Platform.operatingSystem;
    final osVersion = Platform.operatingSystemVersion;
    final cores = Platform.numberOfProcessors;

    final osName = os[0].toUpperCase() + os.substring(1);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Card(
        elevation: 0,
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          child: Row(
            children: [
              Icon(Icons.computer, color: theme.colorScheme.secondary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'System: $osName ($osVersion) • $cores CPU Cores',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryCard(BuildContext context) {
    final theme = Theme.of(context);
    if (_history.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 16.0),
      child: Card(
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Benchmark History', style: theme.textTheme.titleMedium),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                    label: const Text('Clear'),
                    onPressed: _isRunning ? null : _clearHistory,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _history.length,
                separatorBuilder: (context, index) => const Divider(),
                itemBuilder: (context, index) {
                  final result = _history[index];
                  final timeStr = result.timestamp.toLocal().toString().split(' ').first;
                  final timeOfDay = result.timestamp.toLocal().toString().split(' ')[1].substring(0, 5);
                  final isParallel = result.nszParallel ? 'Parallel' : 'Sequential';
                  final threadStr = result.threadCount == 0 ? 'Auto' : '${result.threadCount}T';
                  final chunkStr = '${result.chunkSizeMB}MB';

                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Row(
                      children: [
                        Text(
                          '${result.savingsPercent.toStringAsFixed(1)}% savings',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: context.semantic.success,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'in ${result.durationSeconds.toStringAsFixed(1)}s',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Text(
                        'Config: $threadStr • $chunkStr • $isParallel • $timeStr $timeOfDay',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    trailing: _isRunning
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.settings_backup_restore),
                            tooltip: 'Reuse settings from this run',
                            onPressed: () {
                              _updateThreadCount(result.threadCount);
                              _updateChunkSize(result.chunkSizeMB);
                              _updateNszParallel(result.nszParallel);
                              _log('Restored settings from run: ${result.savingsPercent.toStringAsFixed(1)}% savings, ${result.durationSeconds.toStringAsFixed(1)}s');
                            },
                          ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDesktop = MediaQuery.of(context).size.width >= 600;

    return Scaffold(
      appBar: AppBar(
        title: const Text('NSZ Performance Benchmark'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: _isRunning ? null : () => context.pop(),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              _buildSystemSpecsHeader(context),

              // Setup Card wrapped in DragDropTarget
              DragDropTarget(
                hintText: 'Drop .nsp or .keys files here',
                onFilesDropped: _handleDroppedFiles,
                child: Card(
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('1. Setup Files', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 12),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Input NSP File'),
                          subtitle: Text(_inputPath.isEmpty ? 'Select an NSP game file to compress' : _inputPath),
                          trailing: FilledButton.icon(
                            icon: const Icon(Icons.folder_open),
                            label: const Text('Browse'),
                            onPressed: _isRunning
                                ? null
                                : () async {
                                    String? file;
                                  if (Platform.isAndroid && context.mounted) {
                                    file = await AndroidFilePicker.pickFile(context, allowedExtensions: ['nsp']);
                                  } else {
                                    file = await FileService.pickAnyFile();
                                  }
                                  if (file != null && file.toLowerCase().endsWith('.nsp')) {
                                    _persistInputPath(file);
                                  }
                                  },
                          ),
                        ),
                        const Divider(),
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('prod.keys File'),
                          subtitle: Text(_keysPath.isEmpty ? 'Select prod.keys keys file' : _keysPath),
                          trailing: FilledButton.icon(
                            icon: const Icon(Icons.key),
                            label: const Text('Browse'),
                            onPressed: _isRunning
                                ? null
                                : () async {
                                    String? file;
                                  if (Platform.isAndroid && context.mounted) {
                                    file = await AndroidFilePicker.pickFile(context);
                                  } else {
                                    file = await FileService.pickAnyFile();
                                  }
                                  if (file != null) {
                                    _persistKeysPath(file);
                                  }
                                  },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Configuration Card
              Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('2. Configure Parameters', style: theme.textTheme.titleMedium),
                          if (!_isRunning)
                            TextButton.icon(
                              icon: const Icon(Icons.settings_backup_restore, size: 18),
                              label: const Text('Reset'),
                              onPressed: () {
                                _updateThreadCount(1);
                                _updateChunkSize(2);
                                _updateNszParallel(true);
                                _log('Settings reset to defaults (1 Thread, 2 MB Chunk, Parallel NCA).');
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Zstandard Threads'),
                        subtitle: Text(_threadCount == 0 ? 'Default (cores - 2)' : '$_threadCount thread(s)'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove),
                              onPressed: _isRunning || _threadCount <= 0
                                  ? null
                                  : () => _updateThreadCount(_threadCount - 1),
                            ),
                            Text(
                              _threadCount == 0 ? 'Auto' : '$_threadCount',
                              style: theme.textTheme.titleMedium,
                            ),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: _isRunning || _threadCount >= 16
                                  ? null
                                  : () => _updateThreadCount(_threadCount + 1),
                            ),
                          ],
                        ),
                      ),
                      const Divider(),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('I/O Chunk Size'),
                        subtitle: Text('$_chunkSizeMB MB'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.remove),
                              onPressed: _isRunning || _chunkSizeMB <= 1
                                  ? null
                                  : () => _updateChunkSize(_chunkSizeMB - 1),
                            ),
                            Text(
                              '$_chunkSizeMB',
                              style: theme.textTheme.titleMedium,
                            ),
                            IconButton(
                              icon: const Icon(Icons.add),
                              onPressed: _isRunning || _chunkSizeMB >= 32
                                  ? null
                                  : () => _updateChunkSize(_chunkSizeMB + 1),
                            ),
                          ],
                        ),
                      ),
                      const Divider(),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Parallel NCA Compression'),
                        subtitle: const Text('Compress multiple NCAs in parallel background isolates'),
                        value: _nszParallel,
                        onChanged: _isRunning
                            ? null
                            : (val) => _updateNszParallel(val),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Benchmark Trigger Button
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (!_isRunning)
                    FilledButton.icon(
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start Benchmark'),
                      onPressed: _startBenchmark,
                    )
                  else
                    FilledButton.icon(
                      icon: const Icon(Icons.stop),
                      label: const Text('Cancel Benchmark'),
                      style: FilledButton.styleFrom(
                        backgroundColor: Theme.of(context).colorScheme.error,
                        foregroundColor: Theme.of(context).colorScheme.onError,
                      ),
                      onPressed: _cancelBenchmark,
                    ),
                ],
              ),
              const SizedBox(height: 20),

              // Status and Progress bar
              if (_isRunning || _progress > 0) ...[
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        'Status: $_statusMessage',
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                    ),
                    if (_isRunning && _speedMBs > 0)
                      Text(
                        '${_speedMBs.toStringAsFixed(1)} MB/s${_etaText.isNotEmpty ? ' • $_etaText' : ''}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: _progress),
                const SizedBox(height: 16),
              ],

              // Results Card (Visible upon completion) with Copy Report Button
              if (_elapsed != null && _inputSize != null && _outputSize != null) ...[
                Card(
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                  elevation: 1,
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.analytics, color: context.semantic.success),
                                const SizedBox(width: 8),
                                Text(
                                  'Benchmark Results',
                                  style: theme.textTheme.titleMedium?.copyWith(
                                    color: theme.colorScheme.onPrimaryContainer,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                            TextButton.icon(
                              icon: const Icon(Icons.share, size: 16),
                              label: const Text('Copy Report'),
                              onPressed: _copyMarkdownReport,
                              style: TextButton.styleFrom(
                                foregroundColor: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        LayoutBuilder(
                          builder: (context, boxConstraints) {
                            final columnWidth = (boxConstraints.maxWidth - 20) / (isDesktop ? 4 : 2);
                            return Wrap(
                              spacing: 5,
                              runSpacing: 16,
                              children: [
                                _buildResultItem(
                                  context: context,
                                  label: 'Total Time',
                                  value: '${(_elapsed!.inMilliseconds / 1000).toStringAsFixed(2)}s',
                                  width: columnWidth,
                                ),
                                _buildResultItem(
                                  context: context,
                                  label: 'Original Size',
                                  value: '${(_inputSize! / 1024 / 1024).toStringAsFixed(2)} MB',
                                  width: columnWidth,
                                ),
                                _buildResultItem(
                                  context: context,
                                  label: 'Compressed Size',
                                  value: '${(_outputSize! / 1024 / 1024).toStringAsFixed(2)} MB',
                                  width: columnWidth,
                                ),
                                _buildResultItem(
                                  context: context,
                                  label: 'Savings Ratio',
                                  value: '${((1 - _outputSize! / _inputSize!) * 100).toStringAsFixed(2)}%',
                                  width: columnWidth,
                                ),
                              ],
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Logging Console Card
              Card(
                elevation: 1,
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('Log', style: theme.textTheme.titleMedium),
                          Row(
                            children: [
                              if (_logs.isNotEmpty) ...[
                                TextButton.icon(
                                  icon: const Icon(Icons.copy, size: 16),
                                  label: const Text('Copy'),
                                  onPressed: () async {
                                    final logText = _logs.join('\n');
                                    await Clipboard.setData(ClipboardData(text: logText));
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                          content: Text('Log copied to clipboard'),
                                          duration: Duration(seconds: 5),
                                        ),
                                      );
                                    }
                                  },
                                ),
                                const SizedBox(width: 8),
                                TextButton.icon(
                                  icon: const Icon(Icons.clear, size: 16),
                                  label: const Text('Clear'),
                                  onPressed: () => setState(() => _logs.clear()),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        height: 250,
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.85),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: _logs.isEmpty
                            ? const Center(
                                child: Text(
                                  'Terminal idle. Press Start Benchmark.',
                                  style: TextStyle(color: Colors.grey, fontFamily: 'monospace'),
                                ),
                              )
                            : SingleChildScrollView(
                                controller: _scrollController,
                                child: SelectableText(
                                  _logs.join('\n'),
                                  style: const TextStyle(
                                    color: Colors.lightGreenAccent,
                                    fontFamily: 'monospace',
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),

              // Benchmark History Card
              _buildHistoryCard(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultItem({
    required BuildContext context,
    required String label,
    required String value,
    required double width,
  }) {
    final theme = Theme.of(context);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

class _BenchmarkResult {
  final DateTime timestamp;
  final int threadCount;
  final int chunkSizeMB;
  final bool nszParallel;
  final double durationSeconds;
  final double savingsPercent;

  _BenchmarkResult({
    required this.timestamp,
    required this.threadCount,
    required this.chunkSizeMB,
    required this.nszParallel,
    required this.durationSeconds,
    required this.savingsPercent,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp.toIso8601String(),
        'threadCount': threadCount,
        'chunkSizeMB': chunkSizeMB,
        'nszParallel': nszParallel,
        'durationSeconds': durationSeconds,
        'savingsPercent': savingsPercent,
      };

  factory _BenchmarkResult.fromJson(Map<String, dynamic> json) => _BenchmarkResult(
        timestamp: DateTime.parse(json['timestamp']),
        threadCount: json['threadCount'] as int,
        chunkSizeMB: json['chunkSizeMB'] as int,
        nszParallel: json['nszParallel'] as bool,
        durationSeconds: (json['durationSeconds'] as num).toDouble(),
        savingsPercent: (json['savingsPercent'] as num).toDouble(),
      );
}
