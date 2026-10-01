import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:video_player/video_player.dart';

import '../../../core/content/lifecycle_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_lifecycle_providers.dart';
import '../../babies/application/baby_providers.dart';
import '../../premium/presentation/premium_store_screen.dart';
import '../../subscription/presentation/family_plan_screen.dart';
import '../application/film_providers.dart';
import '../data/film_repository.dart';
import '../domain/film_models.dart';

const filmRoute = '/film';
const filmViewRoute = '/film/view';

/// Server-backed gate of the film routes: LOCKED + family subscription +
/// purchased film. Family Members see the ready film only.
class FilmRouteGate extends ConsumerWidget {
  const FilmRouteGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(filmAccessProvider(baby.id));
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
      appBar: AppBar(title: const Text('İlk Yıl Filmi')),
      body: switch (a.block) {
        'premium_requires_locked' => EmptyState(
          icon: Icons.hourglass_bottom_rounded,
          title: 'İlk yıl devam ediyor',
          message: closeDate == null
              ? 'Film, ilk yıl arşivi tamamlandıktan sonra hazırlanabilir.'
              : 'Film, ilk yıl arşivi ${Dates.long(closeDate)} tarihinde tamamlandıktan sonra hazırlanabilir.',
          action: FilledButton(onPressed: back, child: const Text('Geri dön')),
        ),
        'entitlement_required' => EmptyState(
          icon: Icons.movie_creation_outlined,
          title: 'İlk Yıl Filmi',
          message: 'Arşiv tamamlandı. Filmi satın aldığınızda fotoğraf, video ve anılardan en fazla 10 dakikalık bir film hazırlanır.',
          action: FilledButton(
            onPressed: () => context.push(premiumStoreRoute(baby.id)),
            child: const Text('Dijital ürünleri gör'),
          ),
        ),
        'subscription_required' => EmptyState(
          icon: Icons.family_restroom_rounded,
          title: 'Aile paketi gerekiyor',
          message:
              'Filminiz korunuyor. Aile paketi aboneliği yeniden etkin olduğunda hazırlayabilir ve indirebilirsiniz.',
          action: FilledButton(onPressed: () => context.push(familyPlanRoute), child: const Text('Aile paketi')),
        ),
        _ => EmptyState(
          icon: Icons.movie_outlined,
          title: 'Film bulunamadı',
          action: FilledButton(onPressed: back, child: const Text('Geri dön')),
        ),
      },
    );
  }
}

class FilmScreen extends ConsumerWidget {
  const FilmScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(filmAccessProvider(baby.id)).value;
    final canEdit = access?.canEdit ?? false;
    final state = ref.watch(filmStateProvider(baby.id));
    return Scaffold(
      appBar: AppBar(title: const Text('İlk Yıl Filmi')),
      body: AsyncValueView<FilmState>(
        value: state,
        onRetry: () => ref.invalidate(filmStateProvider(baby.id)),
        data: (s) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(filmStateProvider(baby.id)),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              if (s.hasFilm) _ReadyFilm(state: s),
              if (canEdit) ...[
                if (s.isWorking) _Progress(state: s),
                if (s.hasFailed) _Failure(babyId: baby.id, state: s),
                _Planner(babyId: baby.id, busy: s.isWorking, rendererEnabled: access?.rendererEnabled ?? false),
              ] else if (!s.hasFilm)
                const EmptyState(
                  icon: Icons.movie_outlined,
                  title: 'Film henüz hazır değil',
                  message: 'Anne veya Baba filmi hazırladığında burada izleyip indirebilirsiniz.',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReadyFilm extends ConsumerWidget {
  const _ReadyFilm({required this.state});

  final FilmState state;

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
                Icon(Icons.movie_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: 10),
                Expanded(child: Text('Filminiz hazır', style: theme.textTheme.titleLarge)),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              [
                if (state.durationMs != null) filmDurationLabel(state.durationMs!),
                if (state.height != null) '${state.height}p',
                state.sizeLabel,
                state.readyLabel,
              ].where((e) => e.isNotEmpty).join(' · '),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 14),
            if (state.canDownload)
              FilledButton.icon(
                onPressed: () async {
                  final file = await runWithProgress(context, () async {
                    final bytes = await ref.read(filmRepositoryProvider).download(state);
                    final dir = await Directory('${(await getApplicationDocumentsDirectory()).path}/films')
                        .create(recursive: true);
                    final f = File('${dir.path}/ilk-yil-filmi.mp4');
                    await f.writeAsBytes(bytes, flush: true);
                    return f;
                  }, message: 'Film indiriliyor…');
                  if (file != null && context.mounted) context.push(filmViewRoute, extra: file);
                },
                icon: const Icon(Icons.download_rounded),
                label: const Text('İndir ve izle'),
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
  'entitlement_required' => 'Film satın alımı etkin değil.',
  'premium_requires_locked' => 'Arşiv yeniden açıkken film indirilemez.',
  _ => 'Film şu anda indirilemiyor.',
};

class _Progress extends StatelessWidget {
  const _Progress({required this.state});

  final FilmState state;

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
                state.jobStatus == 'queued' ? 'Film sırada' : 'Film hazırlanıyor',
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(filmStageLabel(state.progressStage), style: theme.textTheme.bodyMedium),
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

class _Failure extends ConsumerWidget {
  const _Failure({required this.babyId, required this.state});

  final String babyId;
  final FilmState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final media = state.failedMediaId;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        color: theme.colorScheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(filmErrorText(state.lastErrorCode), style: theme.textTheme.bodyLarge),
              if (media != null) ...[
                const SizedBox(height: 12),
                FilledButton.tonal(
                  onPressed: () async {
                    final settings = await ref.read(filmSettingsProvider(babyId).future);
                    if (!context.mounted) return;
                    await runWithProgress(
                      context,
                      () => ref
                          .read(filmRepositoryProvider)
                          .updateSettings(babyId, settings.copyWith(excludedIds: [...settings.excludedIds, media])),
                      success: 'Sorunlu medya filmden çıkarıldı',
                    );
                    ref.invalidate(filmSettingsProvider(babyId));
                  },
                  child: const Text('Bu medyayı filmden çıkar'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Planner extends ConsumerWidget {
  const _Planner({required this.babyId, required this.busy, required this.rendererEnabled});

  final String babyId;
  final bool busy;
  final bool rendererEnabled;

  Future<void> _save(BuildContext context, WidgetRef ref, FilmSettings next, {String? success}) async {
    await runWithProgress(
      context,
      () => ref.read(filmRepositoryProvider).updateSettings(babyId, next),
      success: success,
    );
    ref.invalidate(filmSettingsProvider(babyId));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final settings = ref.watch(filmSettingsProvider(babyId)).value;
    final plan = ref.watch(filmPlanProvider(babyId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Film planı', padding: EdgeInsets.fromLTRB(4, 24, 4, 8)),
        AsyncValueView<FilmPlan>(
          value: plan,
          onRetry: () => ref.invalidate(filmPlanProvider(babyId)),
          data: (p) => Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.overLimit ? '10 dakikayı aşıyor' : 'Tahmini süre: ${filmDurationLabel(p.totalMs)}',
                    style: theme.textTheme.titleLarge?.copyWith(color: p.overLimit ? theme.colorScheme.error : null),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${p.photos} fotoğraf · ${p.videos} video · ${p.memories} anı · ${p.milestones} ilk · ${p.letters} mektup',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    p.overLimit
                        ? 'Seçilen içerik en kısa sahne süreleriyle bile ${filmDurationLabel(p.excessMs)} fazla. Film kesilmez; '
                              'lütfen seçimi azaltın veya önerilen seçimi uygulayın.'
                        : 'Süre içeriğe göre belirlenir; en fazla 10 dakikadır ve az içerikte film uzatılmaz.',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (p.overLimit) ...[
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      onPressed: () async {
                        final suggested = await runWithProgress(
                          context,
                          () => ref.read(filmRepositoryProvider).suggest(babyId),
                        );
                        if (suggested == null || !context.mounted) return;
                        await _save(context, ref, suggested, success: 'Önerilen seçim uygulandı');
                      },
                      icon: const Icon(Icons.auto_fix_high_rounded),
                      label: const Text('Önerilen seçimi uygula'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: busy || p.overLimit || p.isEmpty || !rendererEnabled
                          ? null
                          : () async {
                              await runWithProgress(
                                context,
                                () =>
                                    ref.read(filmRepositoryProvider).requestRender(babyId, 'film-${const Uuid().v4()}'),
                                success: 'Film sıraya alındı',
                              );
                              ref.invalidate(filmStateProvider(babyId));
                            },
                      icon: const Icon(Icons.movie_creation_rounded),
                      label: const Text('Filmi hazırla'),
                    ),
                  ),
                  if (!rendererEnabled)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('Film hazırlama geçici olarak durduruldu.', style: theme.textTheme.bodySmall),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (settings != null) ...[
          const SectionHeader(title: 'Filmde neler olsun?', padding: EdgeInsets.fromLTRB(4, 20, 4, 8)),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('Videolar'),
                  subtitle: const Text('Her videodan en fazla 8 saniye, kendi sesiyle'),
                  value: settings.includeVideos,
                  onChanged: busy ? null : (v) => _save(context, ref, settings.copyWith(includeVideos: v)),
                ),
                SwitchListTile(
                  title: const Text('İlkler'),
                  value: settings.includeMilestones,
                  onChanged: busy ? null : (v) => _save(context, ref, settings.copyWith(includeMilestones: v)),
                ),
                SwitchListTile(
                  title: const Text('Anı yazıları'),
                  value: settings.includeMemoryTexts,
                  onChanged: busy ? null : (v) => _save(context, ref, settings.copyWith(includeMemoryTexts: v)),
                ),
                SwitchListTile(
                  title: const Text('Aile mektupları'),
                  value: settings.includeLetters,
                  onChanged: busy ? null : (v) => _save(context, ref, settings.copyWith(includeLetters: v)),
                ),
                if (settings.excludedIds.isNotEmpty)
                  ListTile(
                    title: Text('${settings.excludedIds.length} fotoğraf / video filmde yok'),
                    trailing: TextButton(
                      onPressed: busy
                          ? null
                          : () => _save(
                              context,
                              ref,
                              settings.copyWith(excludedIds: const []),
                              success: 'Seçim sıfırlandı',
                            ),
                      child: const Text('Sıfırla'),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Filmde müzik yoktur; videolar kendi sesleriyle yer alır. İçerik seçimi kitapta "kitaba ekle" ile işaretlenen '
            'içerikleri kullanır.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// Plays the downloaded film; share / save via the system sheet.
class FilmPlayerScreen extends StatefulWidget {
  const FilmPlayerScreen({super.key, required this.file});

  final File file;

  @override
  State<FilmPlayerScreen> createState() => _FilmPlayerScreenState();
}

class _FilmPlayerScreenState extends State<FilmPlayerScreen> {
  late final VideoPlayerController _controller = VideoPlayerController.file(widget.file);

  @override
  void initState() {
    super.initState();
    _controller.initialize().then((_) {
      if (mounted) setState(() {});
      _controller.play();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('İlk Yıl Filmi'),
        actions: [
          IconButton(
            tooltip: 'Paylaş / Dosyalara kaydet',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: () => SharePlus.instance.share(
              ShareParams(
                files: [XFile(widget.file.path, mimeType: 'video/mp4')],
                fileNameOverrides: ['ilk-yil-filmi.mp4'],
              ),
            ),
          ),
        ],
      ),
      body: !c.value.isInitialized
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: Center(
                    child: GestureDetector(
                      onTap: () => setState(() => c.value.isPlaying ? c.pause() : c.play()),
                      child: AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c)),
                    ),
                  ),
                ),
                VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.all(12)),
              ],
            ),
    );
  }
}
