import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/errors/app_exception.dart';
import '../../babies/domain/baby.dart';
import '../data/book_generator.dart';
import '../data/book_publisher.dart';
import '../domain/book_models.dart';
import 'book_gate.dart';

/// Runs [task] behind a non-dismissible progress dialog. Heavy work (image
/// downscaling on native threads, PDF layout on a background isolate) keeps
/// the UI responsive. Errors are shown as a snackbar; returns null then.
Future<T?> runBookTask<T>(
  BuildContext context,
  String title,
  Future<T> Function(void Function(BookProgress) onProgress) task,
) async {
  final progress = ValueNotifier<BookProgress>(const BookProgress('Hazırlanıyor', 0, 0));
  final navigator = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: ValueListenableBuilder<BookProgress>(
          valueListenable: progress,
          builder: (_, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(p.total > 0 ? '${p.stage} (${p.done}/${p.total})' : p.stage),
              const SizedBox(height: 14),
              LinearProgressIndicator(value: p.fraction),
              const SizedBox(height: 10),
              const Text(
                'Büyük kitaplarda bu işlem birkaç dakika sürebilir. Uygulamayı açık tutun.',
                style: TextStyle(fontSize: 12.5),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  try {
    final result = await task((p) => progress.value = p);
    navigator.pop();
    return result;
  } catch (e) {
    navigator.pop();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(AppException.from(e).message)));
    }
    return null;
  } finally {
    progress.dispose();
  }
}

/// Draft preview from the live archive (never an official artifact).
Future<(File, int)?> generateWithProgress(
  BuildContext context,
  WidgetRef ref,
  BookProject project,
  Baby baby,
  BookQuality quality,
) => runBookTask(
  context,
  quality == BookQuality.print ? 'Baskı kalitesinde kitap' : 'Önizleme hazırlanıyor',
  (onProgress) => ref.read(bookGeneratorProvider).generate(project, baby, quality, onProgress: onProgress),
);

/// Official print-ready PDF: rendered from the sealed snapshot and the frozen
/// configuration, verified and published by the server.
Future<void> publishBook(BuildContext context, WidgetRef ref, Baby baby) async {
  final result = await runBookTask(
    context,
    'Resmî kitap hazırlanıyor',
    (onProgress) => ref.read(bookPublisherProvider).publish(baby.id, onProgress: onProgress),
  );
  if (result == null || !context.mounted) return;
  ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text('Kitap hazır: sürüm ${result.version}, ${result.pageCount} sayfa 📖')));
  context.push(bookViewRoute(baby.id), extra: result.file);
}

/// In-app PDF viewer with print / share / save actions.
class BookPdfViewScreen extends StatelessWidget {
  const BookPdfViewScreen({super.key, required this.file});

  final File file;

  @override
  Widget build(BuildContext context) {
    final name = file.uri.pathSegments.last;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kitap önizleme'),
        actions: [
          IconButton(
            tooltip: 'Paylaş / Dosyalara kaydet',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                files: [XFile(file.path, mimeType: 'application/pdf')],
                fileNameOverrides: [name],
              ),
            ),
          ),
        ],
      ),
      body: PdfPreview(
        build: (_) => file.readAsBytes(),
        pdfFileName: name,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        allowPrinting: true,
        allowSharing: true,
        maxPageWidth: 700,
        loadingWidget: const CircularProgressIndicator(),
      ),
    );
  }
}
