import 'dart:isolate';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../services/file_service.dart';
import '../../services/nsz_worker.dart';
import '../../services/switch_progress.dart';
import 'queue_progress.dart';
import 'package:logging/logging.dart';

// --- Job ---
/// One NSZ operation in a queue: a single compress or decompress with its own
/// input/output and its own tuned parameters (compression level, threads, etc.,
/// which the UI resolves per file). A queue of one is the former single-file
/// behavior.
class NszJob extends Equatable {
  final NszAction action;
  final String inputPath;
  final String outputPath;
  final String? keysPath;
  final int level;
  final int threadCount;
  final int chunkSizeMB;
  final bool nszParallel;
  final int maxConcurrentNcas;

  const NszJob({
    required this.action,
    required this.inputPath,
    required this.outputPath,
    this.keysPath,
    this.level = 18,
    this.threadCount = 0,
    this.chunkSizeMB = 2,
    this.nszParallel = true,
    this.maxConcurrentNcas = 1 << 30,
  });

  @override
  List<Object?> get props => [
        action,
        inputPath,
        outputPath,
        keysPath,
        level,
        threadCount,
        chunkSizeMB,
        nszParallel,
        maxConcurrentNcas,
      ];
}

// --- Events ---
abstract class NszEvent extends Equatable {
  const NszEvent();
  @override
  List<Object?> get props => [];
}

class StartNsz extends NszEvent {
  /// The files to process, one after another.
  final List<NszJob> jobs;

  const StartNsz({required this.jobs});

  @override
  List<Object?> get props => [jobs];
}

class CancelNsz extends NszEvent {}

class _NszProgressUpdated extends NszEvent {
  final SwitchProgress progress;
  const _NszProgressUpdated(this.progress);
}

class _NszFinished extends NszEvent {
  final NszResultMessage result;
  const _NszFinished(this.result);
}

// --- States ---
abstract class NszState extends Equatable {
  const NszState();
  @override
  List<Object?> get props => [];
}

class NszIdle extends NszState {}

class NszRunning extends NszState {
  final SwitchProgress? lastProgress;
  final QueuePosition position;
  const NszRunning(this.lastProgress, this.position);

  @override
  List<Object?> get props => [lastProgress, position];
}

/// Emitted once the whole queue has finished (or been cancelled). [results]
/// holds one entry per file that ran.
class NszBatchDone extends NszState {
  final List<JobResult> results;
  final Duration duration;

  const NszBatchDone(this.results, {this.duration = Duration.zero});

  @override
  List<Object?> get props => [results, duration];
}

// --- Bloc ---
class NszBloc extends Bloc<NszEvent, NszState> {
  final _logger = Logger('NszBloc');
  Isolate? _isolate;
  ReceivePort? _receivePort;
  String? _tempDirPath;
  DateTime? _startTime;

  // The queue being processed and our position within it.
  List<NszJob> _jobs = const [];
  int _currentIndex = 0;
  final List<JobResult> _results = [];
  bool _queueCancelled = false;

  NszBloc() : super(NszIdle()) {
    on<StartNsz>(_onStartNsz);
    on<CancelNsz>(_onCancelNsz);
    on<_NszProgressUpdated>(_onProgressUpdated);
    on<_NszFinished>(_onNszFinished);
  }

  Future<void> _onStartNsz(StartNsz event, Emitter<NszState> emit) async {
    if (event.jobs.isEmpty) return;
    _logger.info('Starting NSZ queue: ${event.jobs.length} job(s).');
    _cleanup();
    _jobs = event.jobs;
    _currentIndex = 0;
    _results.clear();
    _queueCancelled = false;
    _startTime = DateTime.now();

    await _startJob(_jobs[_currentIndex], emit);
  }

  QueuePosition get _position =>
      QueuePosition(currentIndex: _currentIndex + 1, total: _jobs.length);

  /// Spawns the worker for a single job. Mirrors the original single-file start
  /// path; called once per file in the queue.
  Future<void> _startJob(NszJob job, Emitter<NszState> emit) async {
    _logger.info('NSZ job ${_currentIndex + 1}/${_jobs.length}: '
        'action=${job.action.name}, input=${job.inputPath}');
    emit(NszRunning(null, _position));

    // Created on this (main) isolate so the path can be handed to the worker
    // and reliably deleted on cancel, when the worker's own cleanup is skipped.
    _tempDirPath = await FileService.createScratchDir();

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is SwitchProgress) {
        add(_NszProgressUpdated(message));
      } else if (message is NszResultMessage) {
        add(_NszFinished(message));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        NszWorker.runNsz,
        NszParams(
          action: job.action,
          inputPath: job.inputPath,
          outputPath: job.outputPath,
          keysPath: job.keysPath,
          level: job.level,
          threadCount: job.threadCount,
          chunkSizeMB: job.chunkSizeMB,
          nszParallel: job.nszParallel,
          maxConcurrentNcas: job.maxConcurrentNcas,
          tempDirPath: _tempDirPath,
          sendPort: _receivePort!.sendPort,
        ),
      );
    } catch (e) {
      add(_NszFinished(NszResultMessage(success: false, error: e.toString())));
    }
  }

  void _onCancelNsz(CancelNsz event, Emitter<NszState> emit) {
    _queueCancelled = true;
    _cleanup();
    emit(_doneState());
  }

  void _onProgressUpdated(_NszProgressUpdated event, Emitter<NszState> emit) {
    emit(NszRunning(event.progress, _position));
  }

  void _onNszFinished(_NszFinished event, Emitter<NszState> emit) {
    final job = _jobs[_currentIndex];
    _cleanup();

    if (event.result.success) {
      _results.add(JobResult(
        inputPath: job.inputPath,
        outputPath: event.result.outputPath ?? job.outputPath,
        success: true,
      ));
    } else {
      _logger.severe('NSZ job failed: ${event.result.error}');
      _results.add(JobResult(
        inputPath: job.inputPath,
        success: false,
        error: event.result.error ?? 'Unknown error',
      ));
    }

    _currentIndex++;
    if (!_queueCancelled && _currentIndex < _jobs.length) {
      _startJob(_jobs[_currentIndex], emit);
    } else {
      emit(_doneState());
    }
  }

  NszBatchDone _doneState() {
    final duration =
        _startTime != null ? DateTime.now().difference(_startTime!) : Duration.zero;
    _logger.info('NSZ queue finished: ${_results.successCount}/${_jobs.length} '
        'succeeded in ${duration.inMilliseconds}ms.');
    return NszBatchDone(List.unmodifiable(_results), duration: duration);
  }

  void _cleanup() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
    // On a successful finish the worker already removed this; on cancel the
    // killed isolate skipped its own cleanup, so delete it here. Fire-and-forget.
    final tempDirPath = _tempDirPath;
    _tempDirPath = null;
    if (tempDirPath != null) {
      FileService.deleteScratchDir(tempDirPath);
    }
  }

  @override
  Future<void> close() {
    _cleanup();
    return super.close();
  }
}
