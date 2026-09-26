import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/upload_queue.dart';
import '../domain/pending_upload.dart';

/// Shows queued / running / failed uploads above the bottom navigation.
class UploadStatusBar extends ConsumerWidget {
  const UploadStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(uploadQueueProvider);
    if (queue.isEmpty) return const SizedBox.shrink();
    final failed = queue.where((u) => u.state == UploadState.failed).length;
    final active = queue.length - failed;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: failed > 0 ? scheme.errorContainer : scheme.secondaryContainer,
      child: InkWell(
        onTap: () => _showDetails(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              if (active > 0)
                const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                Icon(Icons.error_outline_rounded, size: 18, color: scheme.onErrorContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  [
                    if (active > 0) '$active dosya yükleniyor…',
                    if (failed > 0) '$failed dosya yüklenemedi',
                  ].join(' · '),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              if (failed > 0)
                TextButton(
                  onPressed: () => ref.read(uploadQueueProvider.notifier).retryFailed(),
                  child: const Text('Tekrar dene'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDetails(BuildContext context, WidgetRef ref) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final queue = ref.watch(uploadQueueProvider);
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                const ListTile(
                  title: Text('Yüklemeler', style: TextStyle(fontWeight: FontWeight.w800)),
                  subtitle: Text('Bağlantı koparsa yüklemeler otomatik olarak kaldığı yerden devam eder.'),
                ),
                for (final u in queue)
                  ListTile(
                    leading: Icon(u.kind.name == 'video' ? Icons.videocam_outlined : Icons.photo_outlined),
                    title: Text(switch (u.state) {
                      UploadState.queued => 'Sırada',
                      UploadState.uploading => 'Yükleniyor…',
                      UploadState.failed => 'Başarısız',
                    }),
                    subtitle: u.error == null ? null : Text(u.error!),
                    trailing: IconButton(
                      tooltip: 'İptal et',
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => ref.read(uploadQueueProvider.notifier).cancel(u.id),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
