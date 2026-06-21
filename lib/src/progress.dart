/// The processing phase a [CryptoProgress] event refers to.
enum CryptoPhase {
  /// High-level informational message (e.g. detected encryption method).
  info,

  /// Per-partition start/skip notices.
  partition,

  /// ExHeader (extended header) region.
  exHeader,

  /// ExeFS filename table.
  exeFsFilenameTable,

  /// The `.code` file inside ExeFS (re-keyed for 7.x / New3DS titles).
  exeFsCode,

  /// Main ExeFS body.
  exeFs,

  /// RomFS region.
  romFs,

  /// Trailing-padding trim (new-file decrypt only): file shrunk to used size.
  trim,

  /// The ROM was already fully decrypted, so nothing was written.
  alreadyDecrypted,

  /// Whole-file completion.
  done,
}

/// A structured progress event, replacing the `print` / `\r` console output of
/// the original Python scripts so a Flutter UI can render partition, phase and
/// percentage.
class CryptoProgress {
  /// Partition index 0-7, or -1 for file-level messages.
  final int partition;

  /// Which region/phase this event describes.
  final CryptoPhase phase;

  /// Megabytes processed so far within [phase] (0 when not size-based).
  final int currentMb;

  /// Total megabytes for [phase] (0 when not size-based).
  final int totalMb;

  /// Human-readable message mirroring the script's console output.
  final String message;

  /// True when [phase] (or the whole file, for [CryptoPhase.done]) is finished.
  final bool done;

  const CryptoProgress({
    required this.partition,
    required this.phase,
    this.currentMb = 0,
    this.totalMb = 0,
    this.message = '',
    this.done = false,
  });

  /// Fraction in [0, 1] for size-based phases, else null.
  double? get fraction => totalMb > 0 ? (currentMb / totalMb).clamp(0, 1) : null;

  @override
  String toString() => message.isNotEmpty
      ? message
      : 'Partition $partition ${phase.name} $currentMb/$totalMb mb';
}

/// Callback invoked at the same points the Python scripts printed progress.
typedef ProgressCallback = void Function(CryptoProgress progress);
