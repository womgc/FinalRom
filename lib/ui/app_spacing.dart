import 'package:flutter/widgets.dart';

/// Named spacing constants so padding and gaps stay consistent across the UI
/// instead of being re-declared as bare literals in every widget.
abstract class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;

  /// Standard padding for a screen body / tab content.
  static const EdgeInsets page = EdgeInsets.all(md);

  /// Standard inner padding for a [Card].
  static const EdgeInsets card = EdgeInsets.all(md);

  static const SizedBox gapXs = SizedBox(height: xs);
  static const SizedBox gapSm = SizedBox(height: sm);
  static const SizedBox gapMd = SizedBox(height: md);
  static const SizedBox gapLg = SizedBox(height: lg);
  static const SizedBox gapXl = SizedBox(height: xl);
}
