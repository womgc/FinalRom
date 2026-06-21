import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../settings/app_settings.dart';

/// Shared dialog helpers so confirm / input / conflict prompts look and behave
/// identically everywhere instead of being re-built inline in each screen.

/// A yes/no confirmation. Returns `true` only if the user confirms.
///
/// When [destructive] is true the confirm action is tinted with the error color
/// to signal an irreversible operation (e.g. overwriting the original file).
Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String? confirmLabel,
  String? denyLabel,
  bool destructive = false,
}) async {
  final loc = AppLocalizations.of(context)!;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(denyLabel ?? loc.btnNo),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive
              ? TextButton.styleFrom(foregroundColor: Theme.of(ctx).colorScheme.error)
              : null,
          child: Text(confirmLabel ?? loc.btnYes),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// A single-field text input prompt. Returns the entered text, or `null` if the
/// user cancels.
Future<String?> inputDialog(
  BuildContext context, {
  required String title,
  String initialValue = '',
  String? helperText,
  TextInputType? keyboardType,
}) {
  final loc = AppLocalizations.of(context)!;
  final controller = TextEditingController(text: initialValue);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: keyboardType,
        decoration: InputDecoration(helperText: helperText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(loc.btnCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, controller.text),
          child: Text(loc.btnSave),
        ),
      ],
    ),
  );
}

/// The 3-way "file already exists" prompt. Returns the chosen [ConflictBehavior]
/// ([ConflictBehavior.overwrite] or [ConflictBehavior.autoRename]), or `null` if
/// the user cancels.
Future<ConflictBehavior?> conflictChoiceDialog(
  BuildContext context,
  String filename,
) {
  final loc = AppLocalizations.of(context)!;
  return showDialog<ConflictBehavior>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(loc.fileConflictTitle),
      content: Text(loc.fileConflictContent(filename)),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(loc.actionCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ConflictBehavior.autoRename),
          child: Text(loc.actionRename),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ConflictBehavior.overwrite),
          child: Text(loc.actionOverwrite),
        ),
      ],
    ),
  );
}
