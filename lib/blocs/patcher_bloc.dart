import 'dart:isolate';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:logging/logging.dart';
import '../patcher/patcher.dart';
import '../services/patch_worker.dart';

// --- Events ---
abstract class PatcherEvent extends Equatable {
  const PatcherEvent();
  @override
  List<Object?> get props => [];
}

class StartPatching extends PatcherEvent {
  final String romPath;
  final String patchPath;
  final String outputPath;
  final bool ignoreChecksum;

  const StartPatching({
    required this.romPath,
    required this.patchPath,
    required this.outputPath,
    this.ignoreChecksum = false,
  });
}

class CancelPatching extends PatcherEvent {}

class _PatchFinished extends PatcherEvent {
  final PatchResult result;
  const _PatchFinished(this.result);
}

// --- States ---
abstract class PatcherState extends Equatable {
  const PatcherState();
  @override
  List<Object?> get props => [];
}

class PatcherIdle extends PatcherState {}

class PatcherRunning extends PatcherState {}

class PatcherSuccess extends PatcherState {
  final String outputPath;
  final Duration duration;

  /// Verification summary (detected format + integrity checks) for the UI to
  /// display. Null if the worker did not report one.
  final PatchReport? report;

  const PatcherSuccess(this.outputPath, this.duration, {this.report});

  @override
  List<Object?> get props => [outputPath, duration, report];
}

class PatcherFailure extends PatcherState {
  final String error;
  const PatcherFailure(this.error);
}

// --- Bloc ---
class PatcherBloc extends Bloc<PatcherEvent, PatcherState> {
  final _logger = Logger('PatcherBloc');
  Isolate? _isolate;
  ReceivePort? _receivePort;
  DateTime? _startTime;

  PatcherBloc() : super(PatcherIdle()) {
    on<StartPatching>(_onStartPatching);
    on<CancelPatching>(_onCancelPatching);
    on<_PatchFinished>(_onPatchFinished);
  }

  Future<void> _onStartPatching(StartPatching event, Emitter<PatcherState> emit) async {
    _logger.info('Starting patching: rom=${event.romPath}, patch=${event.patchPath}');
    _cleanup();
    _startTime = DateTime.now();
    emit(PatcherRunning());

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is PatchResult) {
        add(_PatchFinished(message));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        PatchWorker.runPatch,
        PatchParams(
          romPath: event.romPath,
          patchPath: event.patchPath,
          outputPath: event.outputPath,
          ignoreChecksum: event.ignoreChecksum,
          sendPort: _receivePort!.sendPort,
        ),
      );
    } catch (e) {
      add(_PatchFinished(PatchResult(success: false, error: e.toString())));
    }
  }

  void _onCancelPatching(CancelPatching event, Emitter<PatcherState> emit) {
    _cleanup();
    emit(PatcherIdle());
  }

  void _onPatchFinished(_PatchFinished event, Emitter<PatcherState> emit) {
    _cleanup();
    final duration = _startTime != null ? DateTime.now().difference(_startTime!) : Duration.zero;
    if (event.result.success) {
      emit(PatcherSuccess(event.result.path ?? '', duration,
          report: event.result.report));
    } else {
      emit(PatcherFailure(event.result.error ?? 'Unknown error'));
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
