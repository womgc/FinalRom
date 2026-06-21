import 'dart:isolate';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import '../../services/nsp_merge_worker.dart';
import '../../services/switch_progress.dart';
import 'package:logging/logging.dart';

// --- Events ---
abstract class NspMergeEvent extends Equatable {
  const NspMergeEvent();
  @override
  List<Object?> get props => [];
}

class StartNspMerge extends NspMergeEvent {
  final List<String> inputNspPaths;
  final String outputPath;

  const StartNspMerge({
    required this.inputNspPaths,
    required this.outputPath,
  });

  @override
  List<Object?> get props => [inputNspPaths, outputPath];
}

class CancelNspMerge extends NspMergeEvent {}

class _MergeProgressUpdated extends NspMergeEvent {
  final SwitchProgress progress;
  const _MergeProgressUpdated(this.progress);
}

class _MergeFinished extends NspMergeEvent {
  final MergeResultMessage result;
  const _MergeFinished(this.result);
}

// --- States ---
abstract class NspMergeState extends Equatable {
  const NspMergeState();
  @override
  List<Object?> get props => [];
}

class NspMergeIdle extends NspMergeState {}

class NspMergeRunning extends NspMergeState {
  final SwitchProgress? lastProgress;
  const NspMergeRunning(this.lastProgress);

  @override
  List<Object?> get props => [lastProgress];
}

class NspMergeSuccess extends NspMergeState {
  final String outputPath;
  final Duration duration;
  final int? memberCount;
  
  const NspMergeSuccess(this.outputPath, {this.duration = Duration.zero, this.memberCount});

  @override
  List<Object?> get props => [outputPath, duration, memberCount];
}

class NspMergeFailure extends NspMergeState {
  final String error;
  const NspMergeFailure(this.error);

  @override
  List<Object?> get props => [error];
}

// --- Bloc ---
class NspMergeBloc extends Bloc<NspMergeEvent, NspMergeState> {
  final _logger = Logger('NspMergeBloc');
  Isolate? _isolate;
  ReceivePort? _receivePort;
  DateTime? _startTime;

  NspMergeBloc() : super(NspMergeIdle()) {
    on<StartNspMerge>(_onStartNspMerge);
    on<CancelNspMerge>(_onCancelNspMerge);
    on<_MergeProgressUpdated>(_onProgressUpdated);
    on<_MergeFinished>(_onMergeFinished);
  }

  Future<void> _onStartNspMerge(StartNspMerge event, Emitter<NspMergeState> emit) async {
    _logger.info('Starting NSP Merge: base=${event.inputNspPaths.first}, total=${event.inputNspPaths.length}');
    _cleanup();
    _startTime = DateTime.now();
    emit(const NspMergeRunning(null));

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is SwitchProgress) {
        add(_MergeProgressUpdated(message));
      } else if (message is MergeResultMessage) {
        add(_MergeFinished(message));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        NspMergeWorker.runMerge,
        MergeParams(
          inputNspPaths: event.inputNspPaths,
          outputPath: event.outputPath,
          sendPort: _receivePort!.sendPort,
        ),
      );
    } catch (e) {
      add(_MergeFinished(MergeResultMessage(success: false, error: e.toString())));
    }
  }

  void _onCancelNspMerge(CancelNspMerge event, Emitter<NspMergeState> emit) {
    _cleanup();
    emit(NspMergeIdle());
  }

  void _onProgressUpdated(_MergeProgressUpdated event, Emitter<NspMergeState> emit) {
    emit(NspMergeRunning(event.progress));
  }

  void _onMergeFinished(_MergeFinished event, Emitter<NspMergeState> emit) {
    _cleanup();
    final duration = _startTime != null ? DateTime.now().difference(_startTime!) : Duration.zero;
    if (event.result.success) {
      _logger.info('NSP Merge finished successfully in ${duration.inMilliseconds}ms.');
      emit(NspMergeSuccess(
        event.result.outputPath ?? '',
        duration: duration,
        memberCount: event.result.memberCount,
      ));
    } else {
      _logger.severe('NSP Merge failed: ${event.result.error}');
      emit(NspMergeFailure(event.result.error ?? 'Unknown error'));
    }
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
