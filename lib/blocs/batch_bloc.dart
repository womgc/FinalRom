import 'dart:isolate';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:final_rom/final_rom.dart';
import '../../services/crypto_worker.dart';
import 'package:logging/logging.dart';

// --- Events ---
abstract class BatchEvent extends Equatable {
  const BatchEvent();
  @override
  List<Object?> get props => [];
}

class AddFilesToBatch extends BatchEvent {
  final List<String> paths;
  const AddFilesToBatch(this.paths);
}

class RemoveFileFromBatch extends BatchEvent {
  final String path;
  const RemoveFileFromBatch(this.path);
}

class ClearBatchQueue extends BatchEvent {}

class StartBatch extends BatchEvent {
  final CryptoAction action;
  final String? outputFolder;
  final String keysPath;
  final bool inPlace;
  final bool trim;
  final int parallelism;

  const StartBatch({
    required this.action,
    this.outputFolder,
    required this.keysPath,
    required this.inPlace,
    required this.trim,
    required this.parallelism,
  });
}

class CancelBatch extends BatchEvent {}

class _BatchProgressUpdated extends BatchEvent {
  final String path;
  final CryptoProgress progress;
  const _BatchProgressUpdated(this.path, this.progress);
}

class _BatchWorkerFinished extends BatchEvent {
  final String path;
  final CryptoResult result;
  const _BatchWorkerFinished(this.path, this.result);
}

// --- Models ---
enum BatchItemStatus { pending, running, success, failure }

class BatchItem extends Equatable {
  final String path;
  final BatchItemStatus status;
  final CryptoProgress? lastProgress;
  final String? errorMessage;
  final String? outputPath;
  final String? trimMessage;
  final bool alreadyDecrypted;
  final DateTime? startTime;
  final Duration? duration;

  const BatchItem({
    required this.path,
    this.status = BatchItemStatus.pending,
    this.lastProgress,
    this.errorMessage,
    this.outputPath,
    this.trimMessage,
    this.alreadyDecrypted = false,
    this.startTime,
    this.duration,
  });

  BatchItem copyWith({
    BatchItemStatus? status,
    CryptoProgress? lastProgress,
    String? errorMessage,
    String? outputPath,
    String? trimMessage,
    bool? alreadyDecrypted,
    DateTime? startTime,
    Duration? duration,
  }) {
    return BatchItem(
      path: path,
      status: status ?? this.status,
      lastProgress: lastProgress ?? this.lastProgress,
      errorMessage: errorMessage ?? this.errorMessage,
      outputPath: outputPath ?? this.outputPath,
      trimMessage: trimMessage ?? this.trimMessage,
      alreadyDecrypted: alreadyDecrypted ?? this.alreadyDecrypted,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
    );
  }

  @override
  List<Object?> get props => [path, status, lastProgress, errorMessage, outputPath, trimMessage, alreadyDecrypted, startTime, duration];
}

// --- States ---
abstract class BatchState extends Equatable {
  final List<BatchItem> items;
  const BatchState(this.items);

  @override
  List<Object?> get props => [items, identityHashCode(this)];
}

class BatchIdle extends BatchState {
  const BatchIdle(super.items);
}

class BatchRunning extends BatchState {
  const BatchRunning(super.items);
}

class BatchFinished extends BatchState {
  final Duration totalDuration;
  const BatchFinished(super.items, {this.totalDuration = Duration.zero});

  @override
  List<Object?> get props => [items, totalDuration];
}

// --- Bloc ---
class BatchBloc extends Bloc<BatchEvent, BatchState> {
  final _logger = Logger('BatchBloc');
  final Map<String, Isolate> _activeIsolates = {};
  final Map<String, ReceivePort> _activePorts = {};
  int _parallelism = 1;
  CryptoAction? _currentAction;
  String? _outputFolder;
  String? _keysPath;
  bool _inPlace = false;
  bool _trim = true;
  bool _isRunning = false;
  DateTime? _batchStartTime;

  BatchBloc() : super(const BatchIdle([])) {
    on<AddFilesToBatch>(_onAddFiles);
    on<RemoveFileFromBatch>(_onRemoveFile);
    on<ClearBatchQueue>(_onClearQueue);
    on<StartBatch>(_onStartBatch);
    on<CancelBatch>(_onCancelBatch);
    on<_BatchProgressUpdated>(_onProgressUpdated);
    on<_BatchWorkerFinished>(_onWorkerFinished);
  }

  void _onAddFiles(AddFilesToBatch event, Emitter<BatchState> emit) {
    if (_isRunning) return;
    final newItems = List<BatchItem>.from(state.items);
    for (final path in event.paths) {
      if (!newItems.any((item) => item.path == path)) {
        newItems.add(BatchItem(path: path));
      }
    }
    emit(BatchIdle(newItems));
  }

  void _onRemoveFile(RemoveFileFromBatch event, Emitter<BatchState> emit) {
    if (_isRunning) return;
    final newItems = state.items.where((item) => item.path != event.path).toList();
    emit(BatchIdle(newItems));
  }

  void _onClearQueue(ClearBatchQueue event, Emitter<BatchState> emit) {
    if (_isRunning) return;
    emit(const BatchIdle([]));
  }

  Future<void> _onStartBatch(StartBatch event, Emitter<BatchState> emit) async {
    if (_isRunning || state.items.isEmpty) return;
    _logger.info('Starting batch with ${state.items.length} files. action=${event.action.name}');
    _isRunning = true;
    _batchStartTime = DateTime.now();
    _currentAction = event.action;
    _outputFolder = event.outputFolder;
    _keysPath = event.keysPath;
    _inPlace = event.inPlace;
    _trim = event.trim;
    _parallelism = event.parallelism;

    // Reset all states
    final newItems = state.items.map((e) => BatchItem(path: e.path)).toList();
    emit(BatchRunning(newItems));

    _startNextWorkers(emit);
  }

  void _onCancelBatch(CancelBatch event, Emitter<BatchState> emit) {
    if (!_isRunning) return;
    _isRunning = false;
    _cleanupAll();
    
    // Mark running as failed, leave pending as pending
    final newItems = state.items.map((item) {
      if (item.status == BatchItemStatus.running) {
        return item.copyWith(status: BatchItemStatus.failure, errorMessage: 'Cancelled');
      }
      return item;
    }).toList();
    emit(BatchIdle(newItems));
  }

  void _onProgressUpdated(_BatchProgressUpdated event, Emitter<BatchState> emit) {
    if (!_isRunning) return;
    final index = state.items.indexWhere((item) => item.path == event.path);
    if (index != -1) {
      final newItems = List<BatchItem>.from(state.items);
      String? trimMsg = newItems[index].trimMessage;
      if (event.progress.phase == CryptoPhase.trim && event.progress.partition == -1) {
        trimMsg = event.progress.message;
      }
      final alreadyDecrypted = newItems[index].alreadyDecrypted ||
          event.progress.phase == CryptoPhase.alreadyDecrypted;
      newItems[index] = newItems[index].copyWith(
        lastProgress: event.progress,
        trimMessage: trimMsg,
        alreadyDecrypted: alreadyDecrypted,
      );
      emit(BatchRunning(newItems));
    }
  }

  void _onWorkerFinished(_BatchWorkerFinished event, Emitter<BatchState> emit) {
    _cleanupWorker(event.path);
    
    final index = state.items.indexWhere((item) => item.path == event.path);
    if (index != -1) {
      final newItems = List<BatchItem>.from(state.items);
      final item = newItems[index];
      final duration = item.startTime != null ? DateTime.now().difference(item.startTime!) : null;
      if (event.result.success) {
        _logger.info('Batch item finished successfully: ${item.path} in ${duration?.inMilliseconds}ms');
        newItems[index] = item.copyWith(
          status: BatchItemStatus.success,
          outputPath: event.result.path,
          duration: duration,
        );
      } else {
        _logger.severe('Batch item failed: ${item.path} - error: ${event.result.error}');
        newItems[index] = item.copyWith(
          status: BatchItemStatus.failure,
          errorMessage: event.result.error,
          duration: duration,
        );
      }
      
      if (_isRunning) {
        emit(BatchRunning(newItems));
        _startNextWorkers(emit);
      }
    }
  }

  void _startNextWorkers(Emitter<BatchState> emit) {
    if (!_isRunning) return;

    final pendingItems = state.items.where((item) => item.status == BatchItemStatus.pending).toList();
    
    if (pendingItems.isEmpty && _activeIsolates.isEmpty) {
      _isRunning = false;
      final totalDuration = _batchStartTime != null ? DateTime.now().difference(_batchStartTime!) : Duration.zero;
      emit(BatchFinished(state.items, totalDuration: totalDuration));
      return;
    }

    final newItems = List<BatchItem>.from(state.items);
    bool changed = false;

    for (final item in pendingItems) {
      if (_activePorts.length >= _parallelism) break;

      final index = newItems.indexWhere((i) => i.path == item.path);
      newItems[index] = newItems[index].copyWith(
        status: BatchItemStatus.running, 
        startTime: DateTime.now()
      );
      changed = true;
      _spawnWorker(item.path);
    }

    if (changed) {
      emit(BatchRunning(newItems));
    }
  }

  Future<void> _spawnWorker(String path) async {
    final port = ReceivePort();
    _activePorts[path] = port;

    port.listen((message) {
      if (message is CryptoProgress) {
        add(_BatchProgressUpdated(path, message));
      } else if (message is CryptoResult) {
        add(_BatchWorkerFinished(path, message));
      }
    });

    try {
      final isolate = await Isolate.spawn(
        CryptoWorker.runCrypto,
        IsolateParams(
          action: _currentAction!,
          inputPath: path,
          outputPath: _outputFolder,
          keysPath: _keysPath,
          inPlace: _inPlace,
          trim: _trim,
          sendPort: port.sendPort,
        ),
      );
      _activeIsolates[path] = isolate;
    } catch (e) {
      add(_BatchWorkerFinished(path, CryptoResult(success: false, error: e.toString())));
    }
  }

  void _cleanupWorker(String path) {
    _activeIsolates[path]?.kill(priority: Isolate.immediate);
    _activeIsolates.remove(path);
    _activePorts[path]?.close();
    _activePorts.remove(path);
  }

  void _cleanupAll() {
    for (final isolate in _activeIsolates.values) {
      isolate.kill(priority: Isolate.immediate);
    }
    _activeIsolates.clear();
    for (final port in _activePorts.values) {
      port.close();
    }
    _activePorts.clear();
  }

  @override
  Future<void> close() {
    _cleanupAll();
    return super.close();
  }
}
