import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_lifecycle_providers.dart';
import '../../babies/application/baby_providers.dart';
import '../../premium/presentation/premium_store_screen.dart';
import '../../subscription/presentation/family_plan_screen.dart';
import '../application/archive_providers.dart';
import '../data/archive_repository.dart';
import '../domain/archive_models.dart';

const archiveRoute = '/archive';

/// Server-backed gate: LOCKED + family subscription + purchased archive.
/// Family Members see the ready archive only.
class ArchiveRouteGate extends ConsumerWidget {
  const ArchiveRouteGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(archiveAccessProvider(baby.id));
    final a = access.value;
    if (a == null) {
      return Scaffold(
        appBar: AppBar(),
        body: access.hasError
            ? ErrorView(error: access.error!, onRetry: () => ref.read(lifecycleRevisionProvider.notifier).bump())
            : const LoadingView(),
      );
    }
    if (a.canView) return child;
    void back() => context.canPop() ? context.pop() : context.go('/home');
    final closeDate = ref.watch(babyLifecycleProvider(baby.id)).value?.effectiveCloseDate;
    return Scaffold(
      appBar: AppBar(title: const Text('Çevrimdışı arşiv')),
      body: switch (a.block) {
        'premium_requires_locked' => EmptyState(
          icon: Icons.hourglass_bottom_rounded,
          title: 'İlk yıl devam ediyor',
          message: closeDate == null
              ? 'Çevrimdışı arşiv, ilk yıl arşivi tamamlandıktan sonra hazırlanabilir.'
              : 'Çevrimdışı arşiv, ilk yıl arşivi ${Dates.long(closeDate)} tarihinde tamamlandıktan sonra hazırlanabilir.',
          action: FilledButton(onPressed: back, child: const Text('Geri dön')),
        ),
        'entitlement_required' => EmptyState(
          icon: Icons.folder_zip_outlined,
          title: 'Offline HTML Hatırası',
          message: 'Arşiv tamamlandı. Satın aldığınızda tüm ilk yıl arşivi internetsiz açılan bir pakete dönüşür.',
          action: FilledButton(
            onPressed: () => context.push(premiumStoreRoute(baby.id)),
            child: const Text('Dijital ürünleri gör'),
          ),
        ),
        'subscription_required' => EmptyState(
          icon: Icons.family_restroom_rounded,
          title: 'Aile paketi gerekiyor',
          message:
              'Arşiviniz korunuyor. Aile paketi aboneliği yeniden etkin olduğunda hazırlayabilir ve indirebilirsiniz.',
          action: FilledButton(onPressed: () => context.push(familyPlanRoute), child: const Text('Aile paketi')),
        ),
        _ => EmptyState(
          icon: Icons.folder_off_outlined,
          title: 'Arşiv bulunamadı',
          action: FilledButton(onPressed: back, child: const Text('Geri dön')),
        ),
      },
    );
  }
}

class ArchiveScreen extends ConsumerWidget {
  const ArchiveScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(archiveAccessProvider(baby.id)).value;
    final canCreate = access?.canCreate ?? false;
    final state = ref.watch(archiveStateProvider(baby.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Çevrimdışı arşiv')),
      body: AsyncValueView<ArchiveState>(
        value: state,
        onRetry: () => ref.invalidate(archiveStateProvider(baby.id)),
        data: (s) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(archiveStateProvider(baby.id)),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              if (s.hasArchive) _ReadyArchive(state: s),
              if (canCreate && s.isWorking) _Progress(state: s),
              if (canCreate && s.hasFailed)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(padding: const EdgeInsets.all(20), child: Text(archiveErrorText(s.lastErrorCode))),
                  ),
                ),
              if (canCreate) _Build(babyId: baby.id, state: s, rendererEnabled: access?.rendererEnabled ?? false),
              if (!canCreate && !s.hasArchive)
                const EmptyState(
                  icon: Icons.folder_zip_outlined,
                  title: 'Arşiv henüz hazır değil',
                  message: 'Anne veya Baba arşivi hazırlayıp sizinle paylaştığında buradan indirebilirsiniz.',
                ),
              const _HowToOpen(),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadyArchive extends ConsumerWidget {
  const _ReadyArchive({required this.state});

  final ArchiveState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.folder_zip_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('Arşiviniz hazır', style: theme.textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              [
                state.sizeLabel,
                if (state.entryCount != null) '${state.entryCount} dosya',
                state.readyLabel,
              ].where((e) => e.isNotEmpty).join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
            if (state.skippedMedia > 0) ...[
              const SizedBox(height: 6),
              Text(
                '${state.skippedMedia} fotoğraf / video dönüştürülemediği için pakette yer almıyor; '
                'yerlerinde bir not gösterilir.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 14),
            if (state.canDownload)
              FilledButton.icon(
                onPressed: () async {
                  final file = await runWithProgress(context, () async {
                    final bytes = await ref.read(archiveRepositoryProvider).download(state);
                    final dir = await Directory('${(await getApplicationDocumentsDirectory()).path}/archives')
                        .create(recursive: true);
                    final f = File('${dir.path}/ilk-yil-arsivi.zip');
                    await f.writeAsBytes(bytes, flush: true);
                    return f;
                  }, message: 'Arşiv indiriliyor…');
                  if (file == null || !context.mounted) return;
                  await SharePlus.instance.share(
                    ShareParams(
                      files: [XFile(file.path, mimeType: 'application/zip')],
                      fileNameOverrides: ['ilk-yil-arsivi.zip'],
                    ),
                  );
                },
                icon: const Icon(Icons.download_rounded),
                label: const Text('İndir ve kaydet'),
              )
            else
              Text(_downloadBlockText(state.downloadBlock), style: TextStyle(color: theme.colorScheme.error)),
          ],
        ),
      ),
    );
  }
}

String _downloadBlockText(String? block) => switch (block) {
  'subscription_required' => 'İndirmek için aile paketinin etkin olması gerekiyor.',
  'entitlement_required' => 'Arşiv satın alımı etkin değil.',
  'premium_requires_locked' => 'Arşiv yeniden açıkken indirilemez.',
  'capacity_exceeded' => 'Aile paketinin üye sınırı aşıldığı için aile üyeleri şu anda indiremiyor.',
  'member_downloads_disabled' => 'Aile üyesi indirmeleri geçici olarak kapalı.',
  _ => 'Arşiv şu anda indirilemiyor.',
};

class _Progress extends StatelessWidget {
  const _Progress({required this.state});

  final ArchiveState state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                state.jobStatus == 'queued' ? 'Arşiv sırada' : 'Arşiv hazırlanıyor',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(archiveStageLabel(state.progressStage), style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: state.jobStatus == 'queued' ? null : state.progressPercent / 100,
                minHeight: 6,
                borderRadius: BorderRadius.circular(6),
              ),
              const SizedBox(height: 8),
              Text('Hazırlık sunucuda devam eder; uygulamayı kapatabilirsiniz.', style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _Build extends ConsumerWidget {
  const _Build({required this.babyId, required this.state, required this.rendererEnabled});

  final String babyId;
  final ArchiveState state;
  final bool rendererEnabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    Future<void> request() async {
      await runWithProgress(
        context,
        () => ref.read(archiveRepositoryProvider).request(babyId, 'html-${const Uuid().v4()}'),
        success: 'Arşiv sıraya alındı',
      );
      ref.invalidate(archiveStateProvider(babyId));
    }

    final enabled = rendererEnabled && !state.isWorking;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!state.hasArchive)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: enabled ? request : null,
                icon: const Icon(Icons.folder_zip_rounded),
                label: const Text('Arşivi hazırla'),
              ),
            )
          else
            OutlinedButton.icon(
              onPressed: enabled ? request : null,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Güncel kopyayı kontrol et'),
            ),
          const SizedBox(height: 8),
          Text(
            rendererEnabled
                ? 'Arşiv, mühürlenmiş ilk yıl arşivinin tamamından hazırlanır: anılar, fotoğraflar, videolar, ilkler, '
                      'mektuplar ve yorumlar. Paket değiştirilemez; içine yeni içerik eklenemez.'
                : 'Arşiv hazırlama geçici olarak durduruldu.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _HowToOpen extends StatelessWidget {
  const _HowToOpen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Nasıl açılır?', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              const Text(
                '1. ZIP dosyasını bilgisayarınıza kaydedip bir klasöre çıkarın.\n'
                '2. Klasördeki index.html dosyasını çift tıklayın; arşiv tarayıcınızda açılır.\n'
                '3. İnternet gerekmez. Paket program içermez, kurulum istemez.',
              ),
              const SizedBox(height: 8),
              Text(
                'En iyi deneyim için bilgisayarda Chrome, Edge, Firefox veya Safari önerilir. iPhone / iPad\'de Dosyalar '
                'uygulamasıyla çıkarıp index.html\'i açabilirsiniz.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
