import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../app/theme.dart';
import '../../../core/content/content_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../babies/presentation/baby_app_bar.dart';
import '../../media/application/media_providers.dart';
import '../../media/data/media_repository.dart';
import '../../media/presentation/media_viewer_screen.dart';
import '../../media/presentation/media_widgets.dart';
import '../../memories/data/timeline_repository.dart';
import '../../memories/domain/timeline_entry.dart';
import '../../memories/presentation/timeline_entry_card.dart';

final _monthEntriesProvider = FutureProvider.autoDispose.family<Map<DateTime, List<TimelineEntry>>, (String, DateTime)>((ref, key) async {
  ref.watch(contentRevisionProvider);
  final (babyId, month) = key;
  final from = DateTime.utc(month.year, month.month - 1, 20);
  final to = DateTime.utc(month.year, month.month + 1, 10);
  final entries = await ref.watch(timelineRepositoryProvider).range(babyId, from, to);
  return groupBy(entries, (TimelineEntry e) => Dates.dateOnly(e.date));
});

/// Month calendar; tapping a day lists everything recorded on that day.
class CalendarScreen extends ConsumerStatefulWidget {
  const CalendarScreen({super.key, this.initialDate});

  final DateTime? initialDate;

  @override
  ConsumerState<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends ConsumerState<CalendarScreen> {
  late DateTime _focused = widget.initialDate ?? Dates.today();
  late DateTime _selected = widget.initialDate ?? Dates.today();

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final month = DateTime.utc(_focused.year, _focused.month);
    final entries = ref.watch(_monthEntriesProvider((baby.id, month)));
    final byDay = entries.value ?? const {};
    final dayEntries = byDay[Dates.dateOnly(_selected)] ?? const <TimelineEntry>[];
    final dayMedia = ref.watch(albumProvider(AlbumKey(baby.id, AlbumQuery(from: _selected, to: _selected))));
    final theme = Theme.of(context);
    final age = baby.ageOn(_selected);
    final isMonthiversary = age != null && age.days == 0 && age.totalMonths > 0;

    Color colorFor(EntryType t) => switch (t) {
      EntryType.memory => AppColors.memory,
      EntryType.milestone => AppColors.milestone,
      EntryType.letter => AppColors.letter,
    };

    return Scaffold(
      appBar: const BabyAppBar(title: 'Takvim'),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 100),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Card(
              child: TableCalendar<TimelineEntry>(
                locale: 'tr_TR',
                firstDay: DateTime.utc(baby.birthDate.year - 1, 1, 1),
                lastDay: Dates.today(),
                focusedDay: _focused.isAfter(Dates.today()) ? Dates.today() : _focused,
                startingDayOfWeek: StartingDayOfWeek.monday,
                availableCalendarFormats: const {CalendarFormat.month: 'Ay'},
                selectedDayPredicate: (d) => isSameDay(d, _selected),
                eventLoader: (d) => byDay[Dates.dateOnly(d)] ?? const [],
                onDaySelected: (sel, foc) => setState(() {
                  _selected = Dates.dateOnly(sel);
                  _focused = Dates.dateOnly(foc);
                }),
                onPageChanged: (foc) => setState(() => _focused = Dates.dateOnly(foc)),
                headerStyle: HeaderStyle(
                  titleCentered: true,
                  formatButtonVisible: false,
                  titleTextStyle: theme.textTheme.titleMedium!,
                ),
                calendarStyle: CalendarStyle(
                  todayDecoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.25), shape: BoxShape.circle),
                  todayTextStyle: TextStyle(color: theme.colorScheme.onSurface, fontWeight: FontWeight.w800),
                  selectedDecoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                  outsideDaysVisible: false,
                ),
                calendarBuilders: CalendarBuilders(
                  markerBuilder: (context, day, events) {
                    if (events.isEmpty) {
                      if (Dates.isSameDay(Dates.dateOnly(day), baby.birthDate)) {
                        return const Positioned(bottom: 4, child: Icon(Icons.cake_rounded, size: 12, color: AppColors.apricot));
                      }
                      return null;
                    }
                    final types = events.map((e) => e.type).toSet().take(3);
                    return Positioned(
                      bottom: 5,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final t in types)
                            Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.symmetric(horizontal: 1),
                              decoration: BoxDecoration(color: colorFor(t), shape: BoxShape.circle),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(Dates.longWithWeekday(_selected), style: theme.textTheme.titleLarge),
                Text(
                  age == null
                      ? 'Doğumdan önce'
                      : isMonthiversary
                          ? '${baby.firstName} bugün ${age.totalMonths} aylık oldu 🎉'
                          : '${baby.firstName} ${age.label}',
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (entries.isLoading && !entries.hasValue) const LoadingView(),
          if (entries.hasError && !entries.hasValue)
            ErrorView(error: entries.error!, compact: true, onRetry: () => ref.invalidate(_monthEntriesProvider((baby.id, month)))),
          for (final e in dayEntries)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: TimelineEntryCard(entry: e, baby: baby, compact: true),
            ),
          if ((dayMedia.value?.items.isNotEmpty ?? false)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('Bu günün fotoğraf ve videoları', style: theme.textTheme.titleSmall),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
                children: [
                  for (var i = 0; i < dayMedia.value!.items.length; i++)
                    MediaThumb(
                      media: dayMedia.value!.items[i],
                      radius: 10,
                      onTap: () => context.push('/viewer', extra: MediaViewerArgs(media: dayMedia.value!.items, initialIndex: i)),
                    ),
                ],
              ),
            ),
          ],
          if (dayEntries.isEmpty && !(dayMedia.value?.items.isNotEmpty ?? false) && entries.hasValue)
            Padding(
              padding: const EdgeInsets.all(20),
              child: OutlinedButton.icon(
                onPressed: () => context.push('/memory/new?date=${Dates.toSql(_selected)}'),
                icon: const Icon(Icons.add_rounded),
                label: const Text('Bu güne bir anı ekle'),
              ),
            ),
        ],
      ),
    );
  }
}
