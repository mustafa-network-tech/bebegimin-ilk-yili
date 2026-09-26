import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import '../../../core/content/content_revision.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/storage_image.dart';
import '../../babies/application/baby_providers.dart';
import '../../family/application/family_providers.dart';
import '../../memories/application/memory_providers.dart';
import '../../memories/domain/comment.dart';
import '../data/media_repository.dart';
import '../domain/media_item.dart';

class MediaViewerArgs {
  const MediaViewerArgs({required this.media, this.initialIndex = 0});

  final List<MediaItem> media;
  final int initialIndex;
}

/// Full screen photo / video viewer with caption, tags, favourite,
/// "kitaba dahil et", sharing and deletion.
class MediaViewerScreen extends ConsumerStatefulWidget {
  const MediaViewerScreen({super.key, required this.args});

  final MediaViewerArgs args;

  @override
  ConsumerState<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends ConsumerState<MediaViewerScreen> {
  late final PageController _page = PageController(initialPage: widget.args.initialIndex);
  late List<MediaItem> _items = [...widget.args.media];
  late int _index = widget.args.initialIndex.clamp(0, widget.args.media.length - 1);
  bool _chrome = true;

  MediaItem get _current => _items[_index];

  @override
  void dispose() {
    _page.dispose();
    super.dispose();
  }

  Future<void> _edit() async {
    final captionCtrl = TextEditingController(text: _current.caption);
    final tagsCtrl = TextEditingController(text: _current.tags.join(', '));
    DateTime date = _current.takenOn;
    final baby = ref.read(activeBabyProvider);
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Fotoğraf bilgileri'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: captionCtrl, decoration: const InputDecoration(labelText: 'Açıklama'), maxLines: 3, maxLength: 2000),
                const SizedBox(height: 8),
                TextField(
                  controller: tagsCtrl,
                  decoration: const InputDecoration(labelText: 'Etiketler', helperText: 'Virgülle ayırın: deniz, tatil'),
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: const Text('Tarih'),
                  subtitle: Text(Dates.long(date)),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: date,
                      firstDate: baby == null ? DateTime(2000) : Dates.addDays(baby.birthDate, -300),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setLocal(() => date = Dates.dateOnly(picked));
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Vazgeç')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Kaydet')),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final tags = tagsCtrl.text.split(',').map((t) => t.trim()).where((t) => t.isNotEmpty).toList();
    final updated = await runWithProgress(
      context,
      () => ref.read(mediaRepositoryProvider).update(_current.id, caption: captionCtrl.text.trim(), tags: tags, takenOn: date),
      success: 'Kaydedildi',
    );
    if (updated != null) {
      setState(() => _items[_index] = updated);
      ref.read(contentRevisionProvider.notifier).bump();
    }
  }

  Future<void> _toggleBook() async {
    final m = _current;
    final updated = await runWithProgress(
      context,
      () => ref.read(mediaRepositoryProvider).update(m.id, includeInBook: !m.includeInBook),
    );
    if (updated != null) {
      setState(() => _items[_index] = updated);
      if (mounted) showSnack(context, updated.includeInBook ? 'Kitaba dahil edilecek' : 'Kitap dışında bırakıldı');
      ref.read(contentRevisionProvider.notifier).bump();
    }
  }

  Future<void> _delete() async {
    final ok = await confirm(context,
        title: 'Silinsin mi?', message: 'Bu ${_current.isVideo ? 'video' : 'fotoğraf'} kalıcı olarak silinecek.', confirmLabel: 'Sil', destructive: true);
    if (!ok || !mounted) return;
    final m = _current;
    final done = await runWithProgress(context, () async {
      await ref.read(mediaRepositoryProvider).delete(m);
      return true;
    });
    if (done == true && mounted) {
      ref.read(contentRevisionProvider.notifier).bump();
      if (_items.length == 1) {
        Navigator.pop(context);
      } else {
        setState(() {
          _items = [..._items]..removeAt(_index);
          _index = _index.clamp(0, _items.length - 1);
        });
      }
    }
  }

  Future<void> _share() async {
    final m = _current;
    await runWithProgress(context, () async {
      final url = await ref.read(signedUrlCacheProvider).url(Buckets.babyMedia, m.storagePath);
      final res = await http.get(Uri.parse(url));
      if (res.statusCode != 200) throw const HttpException('indirilemedi');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${m.id}.${m.isVideo ? m.storagePath.split('.').last : 'jpg'}');
      await file.writeAsBytes(res.bodyBytes);
      await SharePlus.instance.share(ShareParams(files: [XFile(file.path, mimeType: m.mimeType)]));
    }, message: 'Hazırlanıyor…');
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    final access = ref.watch(activeAccessProvider);
    final favorites = baby == null ? const <String>{} : (ref.watch(favoritesProvider(baby.id)).value ?? const <String>{});
    final m = _current;
    final canEdit = access.canEditMedia(m.uploaderId);
    final isFav = favorites.contains(m.id);
    final uploader = baby == null ? '' : ref.watch(authorNameProvider((baby.id, m.uploaderId)));
    final age = baby?.ageOn(m.takenOn);

    return Theme(
      data: ThemeData.dark(useMaterial3: true).copyWith(textTheme: Theme.of(context).textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white)),
      child: Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: _chrome
            ? AppBar(
                backgroundColor: Colors.black38,
                foregroundColor: Colors.white,
                title: Text('${_index + 1} / ${_items.length}'),
                actions: [
                  if (baby != null)
                    IconButton(
                      tooltip: 'Favori',
                      icon: Icon(isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                      onPressed: () => ref.read(favoritesProvider(baby.id).notifier).toggle(TargetKind.media, m.id).catchError((Object e) {
                        if (context.mounted) showError(context, e);
                      }),
                    ),
                  IconButton(tooltip: 'Paylaş / kaydet', icon: const Icon(Icons.ios_share_rounded), onPressed: _share),
                  if (canEdit)
                    PopupMenuButton<String>(
                      onSelected: (v) => switch (v) {
                        'edit' => _edit(),
                        'book' => _toggleBook(),
                        'delete' => _delete(),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(value: 'edit', child: Text('Açıklama / etiket / tarih')),
                        PopupMenuItem(value: 'book', child: Text(m.includeInBook ? 'Kitaptan çıkar' : 'Kitaba dahil et')),
                        const PopupMenuItem(value: 'delete', child: Text('Sil')),
                      ],
                    ),
                ],
              )
            : null,
        body: GestureDetector(
          onTap: () => setState(() => _chrome = !_chrome),
          child: Stack(
            children: [
              PageView.builder(
                controller: _page,
                itemCount: _items.length,
                onPageChanged: (i) => setState(() => _index = i),
                itemBuilder: (_, i) {
                  final item = _items[i];
                  if (item.isVideo) return _VideoView(media: item, key: ValueKey(item.id));
                  return InteractiveViewer(
                    minScale: 1,
                    maxScale: 5,
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: item.aspectRatio,
                        child: StorageImage(bucket: Buckets.babyMedia, path: item.storagePath, fit: BoxFit.contain),
                      ),
                    ),
                  );
                },
              ),
              if (_chrome)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: EdgeInsets.fromLTRB(20, 16, 20, 16 + MediaQuery.paddingOf(context).bottom),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.transparent, Colors.black87]),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (m.caption?.isNotEmpty ?? false)
                          Text(m.caption!, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                          [Dates.long(m.takenOn), if (age != null) age.label, if (uploader.isNotEmpty) uploader].join(' · '),
                          style: const TextStyle(color: Colors.white70, fontSize: 12.5),
                        ),
                        if (m.tags.isNotEmpty || !m.includeInBook) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              for (final t in m.tags)
                                Chip(label: Text('#$t'), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                              if (!m.includeInBook)
                                const Chip(label: Text('Kitap dışı'), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VideoView extends ConsumerStatefulWidget {
  const _VideoView({super.key, required this.media});

  final MediaItem media;

  @override
  ConsumerState<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends ConsumerState<_VideoView> {
  VideoPlayerController? _controller;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final url = await ref.read(signedUrlCacheProvider).url(Buckets.babyMedia, widget.media.storagePath);
      final c = VideoPlayerController.networkUrl(Uri.parse(url));
      await c.initialize();
      if (!mounted) {
        await c.dispose();
        return;
      }
      setState(() => _controller = c);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    if (_error != null) {
      return const Center(child: Text('Video oynatılamadı. Bağlantınızı kontrol edin.', style: TextStyle(color: Colors.white70)));
    }
    if (c == null) return const Center(child: CircularProgressIndicator());
    return Center(
      child: AspectRatio(
        aspectRatio: c.value.aspectRatio,
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            VideoPlayer(c),
            ValueListenableBuilder(
              valueListenable: c,
              builder: (_, v, _) => Center(
                child: IconButton.filledTonal(
                  iconSize: 44,
                  onPressed: () => v.isPlaying ? c.pause() : c.play(),
                  icon: Icon(v.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                ),
              ),
            ),
            VideoProgressIndicator(c, allowScrubbing: true, padding: const EdgeInsets.all(12)),
          ],
        ),
      ),
    );
  }
}
