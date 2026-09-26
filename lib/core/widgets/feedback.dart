import 'package:flutter/material.dart';

import '../errors/app_exception.dart';

void showSnack(BuildContext context, String message, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  final scheme = Theme.of(context).colorScheme;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? scheme.error : null,
      ),
    );
}

void showError(BuildContext context, Object error) =>
    showSnack(context, AppException.from(error).message, error: true);

Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Onayla',
  bool destructive = false,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError) : null,
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Runs [task] behind a modal progress indicator and reports errors.
Future<T?> runWithProgress<T>(
  BuildContext context,
  Future<T> Function() task, {
  String? message,
  String? success,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                if (message != null) ...[const SizedBox(height: 16), Text(message)],
              ],
            ),
          ),
        ),
      ),
    ),
  );
  try {
    final result = await task();
    navigator.pop();
    if (success != null && context.mounted) showSnack(context, success);
    return result;
  } catch (e) {
    navigator.pop();
    if (context.mounted) showError(context, e);
    return null;
  }
}
