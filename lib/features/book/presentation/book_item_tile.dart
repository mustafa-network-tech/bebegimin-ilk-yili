import 'package:collection/collection.dart';
import 'package:flutter/material.dart';

import '../../../app/theme.dart';
import '../../../core/utils/dates.dart';
import '../../media/presentation/media_widgets.dart';
import '../domain/book_composer.dart';
import '../domain/book_models.dart';

/// Human readable description of a book item from the loaded source.
class BookItemInfo {
  const BookItemInfo({required this.title, required this.subtitle, required this.icon, required this.color, this.date});

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final DateTime? date;

  static BookItemInfo of(BookSource src, BookItemType type, String refId) {
    switch (type) {
      case BookItemType.memory:
        final m = src.memories.firstWhereOrNull((x) => x.id == refId);
        return BookItemInfo(
          title: m?.title ?? 'Silinmiş anı',
          subtitle: m == null ? '' : Dates.long(m.date),
          icon: Icons.auto_awesome_rounded,
          color: AppColors.memory,
          date: m?.date,
        );
      case BookItemType.milestone:
        final m = src.milestones.firstWhereOrNull((x) => x.id == refId);
        final t = m == null ? null : src.milestoneTypes[m.typeId];
        return BookItemInfo(
          title: t?.title ?? 'İlk',
          subtitle: m == null ? '' : Dates.long(m.achievedOn),
          icon: Icons.star_rounded,
          color: AppColors.milestone,
          date: m?.achievedOn,
        );
      case BookItemType.letter:
        final l = src.letters.firstWhereOrNull((x) => x.id == refId);
        return BookItemInfo(
          title: l?.title ?? 'Mektup',
          subtitle: l == null ? '' : '${l.signature} · ${Dates.long(l.writtenOn)}',
          icon: Icons.mail_rounded,
          color: AppColors.letter,
          date: l?.writtenOn,
        );
      case BookItemType.media:
        final m = src.media.firstWhereOrNull((x) => x.id == refId);
        return BookItemInfo(
          title: m?.caption?.isNotEmpty ?? false ? m!.caption! : (m?.isVideo ?? false ? 'Video karesi' : 'Fotoğraf'),
          subtitle: m == null ? '' : Dates.long(m.takenOn),
          icon: Icons.photo_rounded,
          color: AppColors.photo,
          date: m?.takenOn,
        );
    }
  }
}

class BookItemLeading extends StatelessWidget {
  const BookItemLeading({super.key, required this.source, required this.type, required this.refId});

  final BookSource source;
  final BookItemType type;
  final String refId;

  @override
  Widget build(BuildContext context) {
    if (type == BookItemType.media) {
      final m = source.media.firstWhereOrNull((x) => x.id == refId);
      if (m != null) return SizedBox.square(dimension: 48, child: MediaThumb(media: m, radius: 10, memCacheWidth: 150));
    }
    final info = BookItemInfo.of(source, type, refId);
    return CircleAvatar(backgroundColor: info.color.withValues(alpha: 0.16), child: Icon(info.icon, color: info.color));
  }
}
