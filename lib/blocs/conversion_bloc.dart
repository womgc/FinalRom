import 'dart:isolate';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:final_rom/final_rom.dart';
import '../../services/crypto_worker.dart';
import 'package:logging/logging.dart';

// --- Events ---
abstract class ConversionEvent extends Equatable {
  const ConversionEvent();
  @override
  List<Object?> get props => [];
}

class StartConversion extends ConversionEvent {
  final CryptoAction action;
  final String inputPath;
  final String? outputPath;
  final String keysPath;
  final bool inPlace;
  final bool trim;

  const StartConversion({
    required this.action,
    required this.inputPath,
    this.outputPath,
    required this.keysPath,
    required this.inPlace,
    required this.trim,
  });

  @override
  List<Object?> get props => [action, inputPath, outputPath, keysPath, inPlace, trim];
}

class CancelConversion extends ConversionEvent {}

class _ProgressUpdated extends ConversionEvent {
  final CryptoProgress progress;
  const _ProgressUpdated(this.progress);
}

class _ConversionFinished extends ConversionEvent {
  final CryptoResult result;
  const _ConversionFinished(this.result);
}

// --- States ---
abstract class ConversionState extends Equatable {
  const ConversionState();
  @override
  List<Object?> get props => [];
}

class ConversionIdle extends ConversionState {}

class ConversionRunning extends ConversionState {
  final CryptoProgress? lastProgress;
  const ConversionRunning(this.lastProgress);

  @override
  List<Object?> get props => [lastProgress];
}

class ConversionSuccess extends ConversionState {
  final String outputPath;
  final String? trimMessage;
  final Duration duration;

  /// True when the ROM was already decrypted and no new file was written.
  final bool alreadyDecrypted;

  const ConversionSuccess(
    this.outputPath, {
    this.trimMessage,
    this.duration = Duration.zero,
    this.alreadyDecrypted = false,
  });

  @override
  List<Object?> get props => [outputPath, trimMessage, duration, alreadyDecrypted];
}

class ConversionFailure extends ConversionState {
  final String error;
  const ConversionFailure(this.error);

  @override
  List<Object?> get props => [error];
}

// --- Bloc ---
class ConversionBloc extends Bloc<ConversionEvent, ConversionState> {
  final _logger = Logger('ConversionBloc');
  Isolate? _isolate;
  ReceivePort? _receivePort;
  String? _lastTrimMessage;
  bool _alreadyDecrypted = false;
  DateTime? _startTime;

  ConversionBloc() : super(ConversionIdle()) {
    on<StartConversion>(_onStartConversion);
    on<CancelConversion>(_onCancelConversion);
    on<_ProgressUpdated>(_onProgressUpdated);
    on<_ConversionFinished>(_onConversionFinished);
  }

  Future<void> _onStartConversion(StartConversion event, Emitter<ConversionState> emit) async {
    _logger.info('Starting conversion: action=${event.action.name}, path=${event.inputPath}');
    _cleanup();
    _lastTrimMessage = null;
    _alreadyDecrypted = false;
    _startTime = DateTime.now();
    emit(const ConversionRunning(null));

    _receivePort = ReceivePort();
    _receivePort!.listen((message) {
      if (message is CryptoProgress) {
        if (message.phase == CryptoPhase.trim && message.partition == -1) {
          _lastTrimMessage = message.message;
        }
        if (message.phase == CryptoPhase.alreadyDecrypted) {
          _alreadyDecrypted = true;
        }
        add(_ProgressUpdated(message));
      } else if (message is CryptoResult) {
        add(_ConversionFinished(message));
      }
    });

    try {
      _isolate = await Isolate.spawn(
        CryptoWorker.runCrypto,
        IsolateParams(
          action: event.action,
          inputPath: event.inputPath,
          outputPath: event.outputPath,
          keysPath: event.keysPath,
          inPlace: event.inPlace,
          trim: event.trim,
          sendPort: _receivePort!.sendPort,
        ),
      );
    } catch (e) {
      add(_ConversionFinished(CryptoResult(success: false, error: e.toString())));
    }
  }

  void _onCancelConversion(CancelConversion event, Emitter<ConversionState> emit) {
    _cleanup();
    emit(ConversionIdle());
  }

  void _onProgressUpdated(_ProgressUpdated event, Emitter<ConversionState> emit) {
    emit(ConversionRunning(event.progress));
  }

  void _onConversionFinished(_ConversionFinished event, Emitter<ConversionState> emit) {
    _cleanup();
    final duration = _startTime != null ? DateTime.now().difference(_startTime!) : Duration.zero;
    if (event.result.success) {
      _logger.info('Conversion finished successfully in ${duration.inMilliseconds}ms. Output: ${event.result.path}');
      emit(ConversionSuccess(
        event.result.path ?? '',
        duration: duration,
        trimMessage: _lastTrimMessage,
        alreadyDecrypted: _alreadyDecrypted,
      ));
    } else {
      _logger.severe('Conversion failed: ${event.result.error}');
      emit(ConversionFailure(event.result.error ?? 'Unknown error'));
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
