/// A lightweight progress event for the Switch NSP/NSZ workers, sent over the
/// isolate [SendPort] just like the 3DS [CryptoProgress] events. Kept separate
/// from `CryptoProgress` because NSP/NSZ work is message + fraction based, not
/// partition/phase based.
class SwitchProgress {
  final String message;

  /// Fraction in [0, 1], or null when indeterminate.
  final double? fraction;

  const SwitchProgress(this.message, this.fraction);

  @override
  String toString() => message;
}
