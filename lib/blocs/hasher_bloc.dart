import 'dart:isolate';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:logging/logging.dart';
import '../services/hasher_worker.dart';

// --- Events ---
abstract class HasherEvent extends Equatable {
  const HasherEvent();
  @override
  List<Object?> get props => [];
}

class StartHashing extends HasherEvent {
  final String filePath;
  const StartHashing(this.filePath);
}

class CancelHashing extends HasherEvent {}

class _HashFinished extends HasherEvent {
  final HasherResult result;
  const _HashFinished(this.result);
}

// --- States ---
abstract class HasherState extends Equatable {
  const HasherState();
  @override
  List<Object?> get props => [];
}

class HasherIdle extends HasherState {}

class HasherRunning extends HasherState {}

class HasherSuccess extends HasherState {
  final HasherResult result;
  const HasherSuccess(this.result);
}

class HasherFailure extends HasherState {
  final String error;
  const HasherFailure(this.error);
}

// --- Bloc ---
class HasherBloc extends Bloc<HasherEvent, HasherState> {
  final _logger = Logger('HasherBloc');
  Isolate? _isolate;
  ReceivePort? _receivePort;

  HasherBloc() : super(HasherIdle()) {
    on<StartHashing>(_onStartHashing);
    on<CancelHashing>(_onCancelHashing);
    on<_HashFinished>(_onHashFinished);
  }

  Future<void> _onStartHashing(StartHashing event, Emitter<HasherState> emit) async {
    _logger.info('Starting hashing for: ${event.filePath}');
    _cleanup();
    emit(HasherRunning());

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is HasherResult) {
        add(_HashFinished(message));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        HasherWorker.runHasher,
        HasherParams(
          filePath: event.filePath,
          sendPort: _receivePort!.sendPort,
        ),
      );
    } catch (e) {
      add(_HashFinished(HasherResult(success: false, error: e.toString())));
    }
  }

  void _onCancelHashing(CancelHashing event, Emitter<HasherState> emit) {
    _cleanup();
    emit(HasherIdle());
  }

  void _onHashFinished(_HashFinished event, Emitter<HasherState> emit) {
    _cleanup();
    if (event.result.success) {
      emit(HasherSuccess(event.result));
    } else {
      emit(HasherFailure(event.result.error ?? 'Unknown error'));
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
