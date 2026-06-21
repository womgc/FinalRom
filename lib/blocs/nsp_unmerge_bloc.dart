import 'dart:isolate';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../services/nsp_unmerge_worker.dart';
import '../../services/switch_progress.dart';
import '../../switch/unmerger.dart';
import 'queue_progress.dart';
import 'package:logging/logging.dart';

// --- Job ---
/// One unmerge (split) operation in a queue: a single NSP and the directory its
/// titles are written into. The keys file is shared across the whole queue. A
/// queue of one is the former single-file behavior.
class UnmergeJob extends Equatable {
  final String inputNspPath;
  final String outputDir;

  const UnmergeJob({required this.inputNspPath, required this.outputDir});

  @override
  List<Object?> get props => [inputNspPath, outputDir];
}

// --- Events ---
abstract class NspUnmergeEvent extends Equatable {
  const NspUnmergeEvent();
  @override
  List<Object?> get props => [];
}

class StartNspUnmerge extends NspUnmergeEvent {
  /// The files to split, one after another.
  final List<UnmergeJob> jobs;
  final String keysPath;

  const StartNspUnmerge({required this.jobs, required this.keysPath});

  @override
  List<Object?> get props => [jobs, keysPath];
}

class CancelNspUnmerge extends NspUnmergeEvent {}

class _UnmergeProgressUpdated extends NspUnmergeEvent {
  final SwitchProgress progress;
  const _UnmergeProgressUpdated(this.progress);
}

class _UnmergeFinished extends NspUnmergeEvent {
  final UnmergeResultMessage result;
  const _UnmergeFinished(this.result);
}

// --- States ---
abstract class NspUnmergeState extends Equatable {
  const NspUnmergeState();
  @override
  List<Object?> get props => [];
}

class NspUnmergeIdle extends NspUnmergeState {}

class NspUnmergeRunning extends NspUnmergeState {
  final SwitchProgress? lastProgress;
  final QueuePosition position;
  const NspUnmergeRunning(this.lastProgress, this.position);

  @override
  List<Object?> get props => [lastProgress, position];
}

/// Emitted once the whole queue has finished (or been cancelled). [results]
/// holds one entry per file that ran; [allOutputs] aggregates the titles
/// written across every successful file.
class NspUnmergeBatchDone extends NspUnmergeState {
  final List<JobResult> results;
  final List<UnmergedTitleResult> allOutputs;
  final Duration duration;

  const NspUnmergeBatchDone(
    this.results,
    this.allOutputs, {
    this.duration = Duration.zero,
  });

  @override
  List<Object?> get props => [results, allOutputs, duration];
}

// --- Bloc ---
class NspUnmergeBloc extends Bloc<NspUnmergeEvent, NspUnmergeState> {
  final _logger = Logger('NspUnmergeBloc');
  Isolate? _isolate;
  ReceivePort? _receivePort;
  DateTime? _startTime;

  // The queue being processed and our position within it.
  List<UnmergeJob> _jobs = const [];
  String _keysPath = '';
  int _currentIndex = 0;
  final List<JobResult> _results = [];
  final List<UnmergedTitleResult> _allOutputs = [];
  bool _queueCancelled = false;

  NspUnmergeBloc() : super(NspUnmergeIdle()) {
    on<StartNspUnmerge>(_onStartNspUnmerge);
    on<CancelNspUnmerge>(_onCancelNspUnmerge);
    on<_UnmergeProgressUpdated>(_onProgressUpdated);
    on<_UnmergeFinished>(_onUnmergeFinished);
  }

  Future<void> _onStartNspUnmerge(
      StartNspUnmerge event, Emitter<NspUnmergeState> emit) async {
    if (event.jobs.isEmpty) return;
    _logger.info('Starting NSP Unmerge queue: ${event.jobs.length} job(s).');
    _cleanup();
    _jobs = event.jobs;
    _keysPath = event.keysPath;
    _currentIndex = 0;
    _results.clear();
    _allOutputs.clear();
    _queueCancelled = false;
    _startTime = DateTime.now();

    _startJob(_jobs[_currentIndex], emit);
  }

  QueuePosition get _position =>
      QueuePosition(currentIndex: _currentIndex + 1, total: _jobs.length);

  /// Spawns the worker for a single job. Mirrors the original single-file start
  /// path; called once per file in the queue. The [emit] runs synchronously
  /// before the first await, so this stays valid when called fire-and-forget
  /// from the (synchronous) finish handler.
  Future<void> _startJob(UnmergeJob job, Emitter<NspUnmergeState> emit) async {
    _logger.info('NSP Unmerge job ${_currentIndex + 1}/${_jobs.length}: '
        'input=${job.inputNspPath}');
    emit(NspUnmergeRunning(null, _position));

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is SwitchProgress) {
        add(_UnmergeProgressUpdated(message));
      } else if (message is UnmergeResultMessage) {
        add(_UnmergeFinished(message));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        NspUnmergeWorker.runUnmerge,
        UnmergeParams(
          inputNspPath: job.inputNspPath,
          outputDir: job.outputDir,
          keysPath: _keysPath,
          sendPort: _receivePort!.sendPort,
        ),
      );
    } catch (e) {
      add(_UnmergeFinished(UnmergeResultMessage(success: false, error: e.toString())));
    }
  }

  void _onCancelNspUnmerge(CancelNspUnmerge event, Emitter<NspUnmergeState> emit) {
    _queueCancelled = true;
    _cleanup();
    emit(_doneState());
  }

  void _onProgressUpdated(_UnmergeProgressUpdated event, Emitter<NspUnmergeState> emit) {
    emit(NspUnmergeRunning(event.progress, _position));
  }

  void _onUnmergeFinished(_UnmergeFinished event, Emitter<NspUnmergeState> emit) {
    final job = _jobs[_currentIndex];
    _cleanup();

    if (event.result.success) {
      final outputs = event.result.outputs ?? [];
      _allOutputs.addAll(outputs);
      _results.add(JobResult(
        inputPath: job.inputNspPath,
        outputPath: job.outputDir,
        success: true,
      ));
    } else {
      _logger.severe('NSP Unmerge job failed: ${event.result.error}');
      _results.add(JobResult(
        inputPath: job.inputNspPath,
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

  NspUnmergeBatchDone _doneState() {
    final duration =
        _startTime != null ? DateTime.now().difference(_startTime!) : Duration.zero;
    _logger.info('NSP Unmerge queue finished: ${_results.successCount}/${_jobs.length} '
        'succeeded in ${duration.inMilliseconds}ms.');
    return NspUnmergeBatchDone(
      List.unmodifiable(_results),
      List.unmodifiable(_allOutputs),
      duration: duration,
    );
  }

  void _cleanup() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
  }

  @override
  Future<void> close() {
    _cleanup();
    return super.close();
  }
}
