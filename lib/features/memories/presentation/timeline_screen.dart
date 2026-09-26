import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/baby_age.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../babies/presentation/baby_app_bar.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../application/memory_providers.dart';
import '../data/timeline_repository.dart';
import '../domain/timeline_entry.dart';
import 'timeline_entry_card.dart';

enum _Filter { all, memories, firsts, letters, firstYear }

/// Chronological archive (newest first), grouped by age period and month.
/// The archive never closes: entries continue after the first birthday.
class TimelineScreen extends ConsumerStatefulWidget {
  const TimelineScreen({super.key});

  @override
  ConsumerState<TimelineScreen> createState() => _TimelineScreenState();
}

class _TimelineScreenState extends ConsumerState<TimelineScreen> {
  _Filter _filter = _Filter.all;
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  TimelineKey? _key() {
    final baby = ref.read(activeBabyProvider);
    if (baby == null) return null;
    final fy = baby.firstYear;
    return TimelineKey(baby.id, switch (_filter) {
      _Filter.all => const TimelineQuery(),
      _Filter.memories => const TimelineQuery(types: {EntryType.memory}),
      _Filter.firsts => const TimelineQuery(types: {EntryType.milestone}),
      _Filter.letters => const TimelineQuery(types: {EntryType.letter}),
      _Filter.firstYear => TimelineQuery(from: Dates.addDays(fy.start, -300), to: fy.firstBirthday),
    });
  }

  void _maybeLoadMore() {
    if (_scroll.position.pixels < _scroll.position.maxScrollExtent - 800) return;
    final key = _key();
    if (key == null) return;
    ref.read(timelineProvider(key).notifier).loadMore().catchError((Object e) {
      if (mounted) showError(context, e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final key = _key()!;
    final timeline = ref.watch(timelineProvider(key));
    final favorites = ref.watch(favoritesProvider(baby.id)).value ?? const <String>{};
    final access = ref.watch(accessProvider(baby.id));
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const BabyAppBar(title: 'Anılar'),
      body: !access.can(AppPermission.viewMemories) && access != MemberAccess.none
          ? const EmptyState(
              icon: Icons.lock_outline_rounded,
              title: 'Anılara erişim yok',
              message: 'Aile yöneticisinden yetki isteyebilirsiniz.',
            )
          : RefreshIndicator(
              onRefresh: () => ref.refresh(timelineProvider(key).future),
              child: CustomScrollView(
                controller: _scroll,
                slivers: [
                  SliverToBoxAdapter(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                      child: Row(
                        children: [
                          for (final (f, label) in [
                            (_Filter.all, 'Tümü'),
                            (_Filter.memories, 'Anılar'),
                            (_Filter.firsts, 'İlkler'),
                            (_Filter.letters, 'Mektuplar'),
                            (_Filter.firstYear, 'İlk Yılım'),
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(label),
                                selected: _filter == f,
                                onSelected: (_) => setState(() => _filter = f),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  AsyncValueView(
                    value: timeline,
                    sliver: true,
                    onRetry: () => ref.invalidate(timelineProvider(key)),
                    data: (state) {
                      if (state.entries.isEmpty) {
                        return const SliverFillRemaining(
                          hasScrollBody: false,
                          child: EmptyState(
                            icon: Icons.auto_stories_outlined,
                            title: 'Henüz bir şey yok',
                            message: 'Bugünü ya da geçmiş bir günü anı olarak ekleyin. Tarihi siz seçersiniz.',
                          ),
                        );
                      }
                      final children = <Widget>[];
                      AgePeriod? lastPeriod;
                      DateTime? lastMonth;
                      for (final e in state.entries) {
                        final period = AgePeriod.forDate(baby.birthDate, e.date);
                        if (period != lastPeriod) {
                          lastPeriod = period;
                          children.add(
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
                              child: Row(
                                children: [
                                  Text(
                                    period?.label ?? 'Doğumdan önce',
                                    style: theme.textTheme.headlineSmall?.copyWith(fontSize: 22),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(child: Divider(color: theme.colorScheme.outlineVariant)),
                                ],
                              ),
                            ),
                          );
                        }
                        final month = DateTime.utc(e.date.year, e.date.month);
                        if (month != lastMonth) {
                          lastMonth = month;
                          children.add(
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 10, 20, 8),
                              child: Text(
                                Dates.monthYear(month).toUpperCase(),
                                style: theme.textTheme.labelLarge?.copyWith(
                                  letterSpacing: 1.2,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          );
                        }
                        children.add(
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: TimelineEntryCard(
                              entry: e,
                              baby: baby,
                              media: state.media[e.id] ?? const [],
                              favorite: favorites.contains(e.id),
                            ),
                          ),
                        );
                      }
                      if (state.loadingMore) {
                        children.add(const Padding(padding: EdgeInsets.all(16), child: LoadingView()));
                      }
                      if (!state.hasMore) {
                        children.add(
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Center(
                              child: Text(
                                '${baby.firstName} ile hikâye burada başlıyor 🤍',
                                style: theme.textTheme.bodySmall,
                              ),
                            ),
                          ),
                        );
                      }
                      children.add(const SizedBox(height: 90));
                      return SliverList.list(children: children);
                    },
                  ),
                ],
              ),
            ),
    );
  }
}
