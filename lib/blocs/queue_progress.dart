import 'package:equatable/equatable.dart';

/// Shared value types used by the CHD, NSZ and NSP-unmerge blocs so that every
/// queue-style operation reports its progress and final summary identically.
///
/// These carry no behavior — they only give the three blocs and their UIs a
/// common shape for "which file are we on" and "how did each file end up".

/// The position of the file currently being processed within a queue.
///
/// [currentIndex] is 1-based for direct display ("File 3 of 5"). [total] is the
/// number of files in the queue. A single-file operation is simply a queue of
/// one, i.e. `QueuePosition(currentIndex: 1, total: 1)`.
class QueuePosition extends Equatable {
  final int currentIndex;
  final int total;

  const QueuePosition({required this.currentIndex, required this.total});

  /// True when the queue holds more than one file, i.e. the UI should show the
  /// "File X of Y" label rather than a plain single-file status.
  bool get isBatch => total > 1;

  @override
  List<Object?> get props => [currentIndex, total];
}

/// The outcome of processing one file in a queue. Collected per file so the UI
/// can show an end-of-queue summary ("4 of 5 done") and surface failures
/// without aborting the remaining files.
class JobResult extends Equatable {
  final String inputPath;
  final String? outputPath;
  final bool success;
  final String? error;

  const JobResult({
    required this.inputPath,
    required this.success,
    this.outputPath,
    this.error,
  });

  @override
  List<Object?> get props => [inputPath, outputPath, success, error];
}

/// Convenience aggregates over a finished queue's [JobResult]s.
extension JobResultsSummary on List<JobResult> {
  int get successCount => where((r) => r.success).length;
  int get failureCount => where((r) => !r.success).length;
  bool get hasFailures => any((r) => !r.success);
}
