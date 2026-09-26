import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/turkish.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../../core/widgets/storage_image.dart';
import '../../babies/application/baby_providers.dart';
import '../../babies/domain/baby.dart';
import '../../babies/presentation/baby_app_bar.dart';
import '../../capsules/application/capsule_providers.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../../memories/application/memory_providers.dart';
import '../../memories/data/timeline_repository.dart';
import '../../memories/presentation/timeline_entry_card.dart';
import '../../milestones/application/milestone_providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final today = Dates.today();
    final oneYearAgo = Dates.addYears(today, -1);
    final timeline = ref.watch(timelineProvider(TimelineKey(baby.id)));
    final onThisDay = ref.watch(timelineProvider(TimelineKey(baby.id, TimelineQuery(from: oneYearAgo, to: oneYearAgo))));
    final access = ref.watch(accessProvider(baby.id));

    Future<void> refresh() async {
      ref.invalidate(timelineProvider(TimelineKey(baby.id)));
      ref.invalidate(babyStatsProvider(baby.id));
      ref.invalidate(membersProvider(baby.id));
      ref.invalidate(babiesProvider);
      await ref.read(timelineProvider(TimelineKey(baby.id)).future);
    }

    return Scaffold(
      appBar: const BabyAppBar(),
      body: RefreshIndicator(
        onRefresh: refresh,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 100),
          children: [
            _Hero(baby: baby, today: today),
            _FirstYearCard(baby: baby, today: today, canCreateBook: access.can(AppPermission.createBook)),
            const _QuickActions(),
            if ((onThisDay.value?.entries.isNotEmpty ?? false)) ...[
              const SectionHeader(title: 'Bir yıl önce bugün ✨'),
              for (final e in onThisDay.value!.entries.take(2))
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                  child: TimelineEntryCard(entry: e, baby: baby, media: onThisDay.value!.media[e.id] ?? const [], compact: true),
                ),
            ],
            SectionHeader(title: 'Son anılar', action: 'Tümü', onAction: () => context.go('/timeline')),
            AsyncValueView(
              value: timeline,
              onRetry: () => ref.invalidate(timelineProvider(TimelineKey(baby.id))),
              data: (state) {
                if (state.entries.isEmpty) {
                  return EmptyState(
                    icon: Icons.auto_awesome_outlined,
                    title: 'İlk anıyı ekleyin',
                    message: '${baby.firstName} için ilk fotoğrafı ya da anıyı eklemek için + düğmesine dokunun.',
                  );
                }
                return Column(
                  children: [
                    for (final e in state.entries.take(4))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                        child: TimelineEntryCard(entry: e, baby: baby, media: state.media[e.id] ?? const [], compact: true),
                      ),
                  ],
                );
              },
            ),
            _Upcoming(baby: baby, today: today),
            _Firsts(baby: baby),
            _Stats(baby: baby),
          ],
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.baby, required this.today});

  final Baby baby;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final age = baby.ageToday(today);
    final headline = age.totalDays == 0
        ? '${baby.firstName} bugün dünyaya geldi 🤍'
        : age.years == 0
            ? '${baby.firstName} bugün ${age.totalDays} günlük ❤️'
            : '${baby.firstName} bugün ${age.label} ❤️';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(28),
        child: SizedBox(
          height: 230,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (baby.coverPath != null)
                StorageImage(bucket: Buckets.babyMedia, path: baby.coverPath)
              else
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFFF1D3C4), Color(0xFFDCE8DF)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0xAA2F2A26)],
                    stops: [0.35, 1],
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 18,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Container(
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3)),
                      child: AppAvatar(name: baby.firstName, bucket: Buckets.babyMedia, path: baby.avatarPath, radius: 32, color: Colors.white),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(headline, style: theme.textTheme.headlineSmall?.copyWith(color: Colors.white, fontSize: 22)),
                          const SizedBox(height: 4),
                          Text(
                            '${age.label} · ${Dates.longWithWeekday(today)}',
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FirstYearCard extends StatelessWidget {
  const _FirstYearCard({required this.baby, required this.today, required this.canCreateBook});

  final Baby baby;
  final DateTime today;
  final bool canCreateBook;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fy = baby.firstYear;
    final complete = fy.isComplete(today);
    final day = fy.dayNumber(today);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        color: AppColors.apricot.withValues(alpha: 0.08),
        child: InkWell(
          onTap: () => context.push('/book'),
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Row(
              children: [
                const CircleAvatar(radius: 24, backgroundColor: AppColors.apricot, child: Icon(Icons.menu_book_rounded, color: Colors.white)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        complete ? '${Turkish.genitive(baby.firstName)} İlk Yılım kitabı hazır olabilir' : 'İlk Yılım · ${day ?? 0}. gün',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 6),
                      if (!complete) ...[
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(value: fy.progress(today), minHeight: 7),
                        ),
                        const SizedBox(height: 6),
                        Text('Kitap için ${fy.daysRemaining(today)} gün kaldı · taslağı şimdiden oluşturabilirsiniz',
                            style: theme.textTheme.bodySmall),
                      ] else
                        Text(
                          canCreateBook ? 'İlk 365 günü kitaba dönüştürün. Anı eklemeye devam edebilirsiniz.' : 'Aile kitabını görüntüleyin.',
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right_rounded),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.photo_library_rounded, 'Albüm', '/album', AppColors.sage),
      (Icons.star_rounded, 'İlklerim', '/milestones', AppColors.honey),
      (Icons.mail_rounded, 'Mektuplar', '/letters', AppColors.lavender),
      (Icons.hourglass_bottom_rounded, 'Kapsül', '/capsules', const Color(0xFF9C8BB0)),
      (Icons.menu_book_rounded, 'Kitabım', '/book', AppColors.apricot),
      (Icons.search_rounded, 'Arama', '/search', const Color(0xFF6E8FB5)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 1.25,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [
          for (final (icon, label, route, color) in items)
            Card(
              child: InkWell(
                onTap: () => context.push(route),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircleAvatar(radius: 20, backgroundColor: color.withValues(alpha: 0.16), child: Icon(icon, color: color, size: 22)),
                    const SizedBox(height: 8),
                    Text(label, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Upcoming extends ConsumerWidget {
  const _Upcoming({required this.baby, required this.today});

  final Baby baby;
  final DateTime today;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final days = [...upcomingDays(baby, today, limit: 3)];
    final capsules = ref.watch(capsulesProvider(baby.id)).value ?? const [];
    for (final c in capsules.where((c) => !c.isOpen(today)).take(2)) {
      days.add(UpcomingDay(date: c.openOn, title: 'Zaman kapsülü: ${c.title}', kind: UpcomingKind.capsule));
    }
    days.sort((a, b) => a.date.compareTo(b.date));
    if (days.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Yaklaşan önemli günler'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Card(
            child: Column(
              children: [
                for (final d in days.take(4))
                  ListTile(
                    leading: Container(
                      width: 48,
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('${d.date.day}', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 17, color: theme.colorScheme.primary)),
                          Text(Dates.dayMonth(d.date).split(' ').last.substring(0, 3), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                        ],
                      ),
                    ),
                    title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    subtitle: Text(Dates.relativeDays(Dates.daysBetween(today, d.date))),
                    onTap: d.kind == UpcomingKind.capsule
                        ? () => context.push('/capsules')
                        : d.kind == UpcomingKind.firstYearComplete
                            ? () => context.push('/book')
                            : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Firsts extends ConsumerWidget {
  const _Firsts({required this.baby});

  final Baby baby;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final slots = ref.watch(milestoneSlotsProvider(baby.id)).value;
    if (slots == null) return const SizedBox.shrink();
    final achieved = slots.where((s) => s.achieved).toList();
    final next = slots.where((s) => !s.achieved).take(3).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: 'İlkler · ${achieved.length}', action: 'Tümü', onAction: () => context.push('/milestones')),
        SizedBox(
          height: 112,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final s in [...achieved.reversed, ...next])
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: SizedBox(
                    width: 112,
                    child: Card(
                      color: s.achieved ? AppColors.honey.withValues(alpha: 0.14) : null,
                      child: InkWell(
                        onTap: () => s.achieved
                            ? context.push('/milestone/${s.milestone!.id}')
                            : context.push('/milestone/new?typeId=${s.type.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(s.type.emoji ?? '⭐', style: TextStyle(fontSize: 26, color: s.achieved ? null : Colors.black.withValues(alpha: 0.35))),
                              const SizedBox(height: 6),
                              Text(s.type.title, textAlign: TextAlign.center, maxLines: 2, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                              if (s.achieved)
                                Text(baby.ageOn(s.milestone!.achievedOn)?.label ?? '', style: const TextStyle(fontSize: 10.5)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Stats extends ConsumerWidget {
  const _Stats({required this.baby});

  final Baby baby;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(babyStatsProvider(baby.id)).value;
    if (stats == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    Widget stat(String v, String l) => Expanded(
      child: Column(
        children: [
          Text(v, style: theme.textTheme.headlineSmall?.copyWith(color: theme.colorScheme.primary)),
          Text(l, style: theme.textTheme.labelMedium),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            children: [
              stat('${stats.memories}', 'anı'),
              stat('${stats.photos}', 'fotoğraf'),
              stat('${stats.videos}', 'video'),
              stat('${stats.milestones}', 'ilk'),
              stat('${stats.letters}', 'mektup'),
            ],
          ),
        ),
      ),
    );
  }
}
