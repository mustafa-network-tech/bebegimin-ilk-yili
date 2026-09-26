import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/utils/dates.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../../family/application/family_providers.dart';
import '../../media/application/media_providers.dart';
import '../../media/data/media_repository.dart';
import '../../media/domain/media_item.dart';
import '../../media/presentation/media_viewer_screen.dart';
import '../../media/presentation/media_widgets.dart';
import '../../memories/application/memory_providers.dart';
import '../../memories/data/timeline_repository.dart';
import '../../memories/domain/timeline_entry.dart';
import '../../memories/presentation/timeline_entry_card.dart';

enum SearchType { all, memories, milestones, letters, photos, videos }

extension on SearchType {
  String get label => switch (this) {
    SearchType.all => 'Tümü',
    SearchType.memories => 'Anılar',
    SearchType.milestones => 'Kilometre taşları',
    SearchType.letters => 'Mektuplar',
    SearchType.photos => 'Fotoğraflar',
    SearchType.videos => 'Videolar',
  };

  bool get isMedia => this == SearchType.photos || this == SearchType.videos;
}

/// Search + filters: text, year, month, date range, type, family member,
/// milestones, favourites, first year.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _text = TextEditingController();
  Timer? _debounce;
  String _query = '';
  SearchType _type = SearchType.all;
  int? _year;
  int? _month;
  DateTimeRange? _range;
  String? _authorId;
  bool _favorites = false;
  bool _firstYear = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _text.dispose();
    super.dispose();
  }

  (DateTime?, DateTime?) _dates(DateTime birth) {
    if (_range != null) return (Dates.dateOnly(_range!.start), Dates.dateOnly(_range!.end));
    if (_firstYear) {
      final fy = firstYearSearchRange(birth);
      return (fy.$1, fy.$2);
    }
    if (_year != null && _month != null) {
      return (DateTime.utc(_year!, _month!, 1), DateTime.utc(_year!, _month! + 1, 0));
    }
    if (_year != null) return (DateTime.utc(_year!, 1, 1), DateTime.utc(_year!, 12, 31));
    return (null, null);
  }

  bool get _hasFilters =>
      _query.isNotEmpty ||
      _type != SearchType.all ||
      _year != null ||
      _range != null ||
      _authorId != null ||
      _favorites ||
      _firstYear;

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final members = ref.watch(membersProvider(baby.id)).value ?? const [];
    final favorites = ref.watch(favoritesProvider(baby.id)).value ?? const <String>{};
    final (from, to) = _dates(baby.birthDate);
    final theme = Theme.of(context);
    final years = [for (var y = Dates.today().year; y >= baby.birthDate.year - 1; y--) y];

    Widget results;
    if (!_hasFilters) {
      results = const EmptyState(
        icon: Icons.manage_search_rounded,
        title: 'Arşivde arayın',
        message: 'Başlık, açıklama veya fotoğraf notu yazın ya da filtreleri kullanın.',
      );
    } else if (_type.isMedia) {
      final key = AlbumKey(
        baby.id,
        AlbumQuery(
          kind: _type == SearchType.photos ? MediaKind.photo : MediaKind.video,
          text: _query.isEmpty ? null : _query,
          from: from,
          to: to,
          ids: _favorites ? favorites : null,
        ),
      );
      final album = ref.watch(albumProvider(key));
      results = AsyncValueView(
        value: album,
        onRetry: () => ref.invalidate(albumProvider(key)),
        data: (s) {
          final items = _authorId == null ? s.items : s.items.where((m) => m.uploaderId == _authorId).toList();
          if (items.isEmpty) return const EmptyState(icon: Icons.search_off_rounded, title: 'Sonuç bulunamadı');
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 4,
              crossAxisSpacing: 4,
            ),
            itemCount: items.length,
            itemBuilder: (_, i) => MediaThumb(
              media: items[i],
              radius: 10,
              onTap: () => context.push(
                '/viewer',
                extra: MediaViewerArgs(media: items, initialIndex: i),
              ),
            ),
          );
        },
      );
    } else {
      final key = TimelineKey(
        baby.id,
        TimelineQuery(
          text: _query.isEmpty ? null : _query,
          types: switch (_type) {
            SearchType.memories => {EntryType.memory},
            SearchType.milestones => {EntryType.milestone},
            SearchType.letters => {EntryType.letter},
            _ => const {},
          },
          from: from,
          to: to,
          authorId: _authorId,
          ids: _favorites ? favorites : null,
        ),
      );
      final timeline = ref.watch(timelineProvider(key));
      results = AsyncValueView(
        value: timeline,
        onRetry: () => ref.invalidate(timelineProvider(key)),
        data: (s) => s.entries.isEmpty
            ? const EmptyState(icon: Icons.search_off_rounded, title: 'Sonuç bulunamadı')
            : NotificationListener<ScrollNotification>(
                onNotification: (n) {
                  if (n.metrics.pixels > n.metrics.maxScrollExtent - 400) {
                    ref.read(timelineProvider(key).notifier).loadMore().ignore();
                  }
                  return false;
                },
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                  itemCount: s.entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (_, i) => TimelineEntryCard(
                    entry: s.entries[i],
                    baby: baby,
                    media: s.media[s.entries[i].id] ?? const [],
                    favorite: favorites.contains(s.entries[i].id),
                    compact: true,
                  ),
                ),
              ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: '${baby.firstName} arşivinde ara…',
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            suffixIcon: _text.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Temizle',
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => setState(() {
                      _text.clear();
                      _query = '';
                    }),
                  ),
          ),
          onChanged: (v) {
            _debounce?.cancel();
            _debounce = Timer(const Duration(milliseconds: 350), () => setState(() => _query = v.trim()));
          },
        ),
      ),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                for (final t in SearchType.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(t.label),
                      selected: _type == t,
                      onSelected: (_) => setState(() => _type = t),
                    ),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Row(
              children: [
                FilterChip(
                  label: const Text('Favoriler'),
                  selected: _favorites,
                  onSelected: (v) => setState(() => _favorites = v),
                ),
                const SizedBox(width: 6),
                FilterChip(
                  label: const Text('İlk Yılım'),
                  selected: _firstYear,
                  onSelected: (v) => setState(() {
                    _firstYear = v;
                    if (v) {
                      _year = null;
                      _month = null;
                      _range = null;
                    }
                  }),
                ),
                const SizedBox(width: 6),
                _Dropdown<int?>(
                  label: _year == null ? 'Yıl' : '$_year',
                  active: _year != null,
                  items: {null: 'Tüm yıllar', for (final y in years) y: '$y'},
                  onSelected: (v) => setState(() {
                    _year = v;
                    if (v == null) _month = null;
                    _range = null;
                    _firstYear = false;
                  }),
                ),
                const SizedBox(width: 6),
                if (_year != null)
                  _Dropdown<int?>(
                    label: _month == null ? 'Ay' : Dates.monthYear(DateTime.utc(_year!, _month!)).split(' ').first,
                    active: _month != null,
                    items: {
                      null: 'Tüm aylar',
                      for (var m = 1; m <= 12; m++) m: Dates.monthYear(DateTime.utc(2024, m)).split(' ').first,
                    },
                    onSelected: (v) => setState(() => _month = v),
                  ),
                const SizedBox(width: 6),
                ActionChip(
                  avatar: const Icon(Icons.date_range_rounded, size: 18),
                  label: Text(
                    _range == null ? 'Tarih aralığı' : '${Dates.short(_range!.start)} – ${Dates.short(_range!.end)}',
                  ),
                  onPressed: () async {
                    final r = await showDateRangePicker(
                      context: context,
                      firstDate: DateTime(baby.birthDate.year - 1),
                      lastDate: DateTime.now(),
                      initialDateRange: _range,
                    );
                    setState(() {
                      _range = r;
                      if (r != null) {
                        _year = null;
                        _month = null;
                        _firstYear = false;
                      }
                    });
                  },
                ),
                const SizedBox(width: 6),
                _Dropdown<String?>(
                  label: _authorId == null
                      ? 'Aile üyesi'
                      : (members.where((m) => m.userId == _authorId).firstOrNull?.shownName ?? 'Üye'),
                  active: _authorId != null,
                  items: {null: 'Herkes', for (final m in members) m.userId: m.introduction},
                  onSelected: (v) => setState(() => _authorId = v),
                ),
                if (_hasFilters)
                  TextButton(
                    onPressed: () => setState(() {
                      _text.clear();
                      _query = '';
                      _type = SearchType.all;
                      _year = null;
                      _month = null;
                      _range = null;
                      _authorId = null;
                      _favorites = false;
                      _firstYear = false;
                    }),
                    child: const Text('Sıfırla'),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          Expanded(child: results),
        ],
      ),
    );
  }
}

(DateTime, DateTime) firstYearSearchRange(DateTime birth) {
  final start = Dates.addDays(birth, -300);
  return (start, Dates.addYears(birth, 1));
}

class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({required this.label, required this.items, required this.onSelected, this.active = false});

  final String label;
  final Map<T, String> items;
  final ValueChanged<T> onSelected;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      onSelected: onSelected,
      itemBuilder: (_) => [for (final e in items.entries) PopupMenuItem<T>(value: e.key, child: Text(e.value))],
      child: Chip(
        label: Text(label),
        avatar: const Icon(Icons.arrow_drop_down_rounded, size: 18),
        backgroundColor: active ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.14) : null,
      ),
    );
  }
}
