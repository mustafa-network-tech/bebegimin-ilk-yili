import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/section_header.dart';
import '../../babies/domain/baby.dart';
import '../../family/application/family_providers.dart';
import '../../media/domain/media_item.dart';
import '../../media/presentation/media_widgets.dart';
import '../domain/timeline_entry.dart';

String entryRoute(TimelineEntry e) => switch (e.type) {
  EntryType.memory => '/memory/${e.id}',
  EntryType.milestone => '/milestone/${e.id}',
  EntryType.letter => '/letter/${e.id}',
};

/// Card used by the timeline, home, calendar and search.
class TimelineEntryCard extends ConsumerWidget {
  const TimelineEntryCard({
    super.key,
    required this.entry,
    required this.baby,
    this.media = const [],
    this.favorite = false,
    this.compact = false,
  });

  final TimelineEntry entry;
  final Baby baby;
  final List<MediaItem> media;
  final bool favorite;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final author = ref.watch(authorNameProvider((baby.id, entry.authorId)));
    final age = baby.ageOn(entry.date);
    final fy = baby.firstYear;
    final (color, icon, label) = switch (entry.type) {
      EntryType.memory => (AppColors.memory, entry.memoryCategory.icon, entry.memoryCategory.label),
      EntryType.milestone => (AppColors.milestone, Icons.star_rounded, 'İlk'),
      EntryType.letter => (AppColors.letter, Icons.mail_rounded, 'Mektup'),
    };
    final time = Dates.timeLabel(entry.time);

    return Card(
      child: InkWell(
        onTap: () => context.push(entryRoute(entry)),
        child: Padding(
          padding: EdgeInsets.all(compact ? 14 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 15,
                    backgroundColor: color.withValues(alpha: 0.16),
                    child: Icon(icon, size: 16, color: color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      [Dates.long(entry.date), ?time].join(' · '),
                      style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                  if (favorite) Icon(Icons.favorite_rounded, size: 16, color: theme.colorScheme.primary),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                entry.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontFamily: 'Lora',
                  fontWeight: FontWeight.w600,
                  fontSize: 18,
                ),
              ),
              if (entry.body?.trim().isNotEmpty ?? false) ...[
                const SizedBox(height: 6),
                Text(
                  entry.body!.trim(),
                  maxLines: compact ? 2 : 4,
                  overflow: TextOverflow.ellipsis,
                  style: entry.type == EntryType.letter
                      ? theme.textTheme.bodyMedium?.copyWith(fontFamily: 'Lora', fontStyle: FontStyle.italic)
                      : theme.textTheme.bodyMedium,
                ),
              ],
              if (media.isNotEmpty && !compact) ...[
                const SizedBox(height: 12),
                MediaCollage(media: media, height: media.length == 1 ? 220 : 180),
              ] else if (media.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      for (final m in media.take(4))
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: SizedBox.square(dimension: 56, child: MediaThumb(media: m, radius: 10)),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Pill(label: label, color: color),
                  if (age != null)
                    Pill(label: age.label, color: theme.colorScheme.secondary)
                  else
                    Pill(label: 'Doğumdan önce', color: theme.colorScheme.secondary),
                  if (fy.isBookCandidate(entry.date) && entry.includeInBook)
                    const Pill(label: 'İlk Yılım', icon: Icons.menu_book_rounded, color: AppColors.apricot),
                  Text(
                    '· $author',
                    style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
