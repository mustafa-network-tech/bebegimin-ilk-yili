import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/storage/signed_urls.dart';
import '../../../core/widgets/storage_image.dart';
import '../domain/media_item.dart';
import 'media_viewer_screen.dart';

/// Square thumbnail for a photo / video.
class MediaThumb extends StatelessWidget {
  const MediaThumb({super.key, required this.media, this.onTap, this.radius = 14, this.favorite = false, this.memCacheWidth = 400});

  final MediaItem media;
  final VoidCallback? onTap;
  final double radius;
  final bool favorite;
  final int memCacheWidth;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: InkWell(
          onTap: onTap,
          child: Stack(
            fit: StackFit.expand,
            children: [
              StorageImage(
                bucket: Buckets.babyMedia,
                path: media.previewPath,
                placeholderIcon: media.isVideo ? Icons.play_circle_outline_rounded : Icons.photo_outlined,
                memCacheWidth: memCacheWidth,
              ),
              if (media.isVideo)
                Positioned(
                  left: 6,
                  bottom: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.play_arrow_rounded, size: 14, color: Colors.white),
                        if (media.durationLabel != null)
                          Text(media.durationLabel!, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                ),
              if (favorite)
                const Positioned(
                  right: 6,
                  top: 6,
                  child: Icon(Icons.favorite_rounded, size: 18, color: Colors.white, shadows: [Shadow(blurRadius: 6)]),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 1–4 photo collage used by timeline cards.
class MediaCollage extends StatelessWidget {
  const MediaCollage({super.key, required this.media, this.height = 200});

  final List<MediaItem> media;
  final double height;

  void _open(BuildContext context, int index) =>
      context.push('/viewer', extra: MediaViewerArgs(media: media, initialIndex: index));

  @override
  Widget build(BuildContext context) {
    if (media.isEmpty) return const SizedBox.shrink();
    const gap = 4.0;
    Widget cell(int i, {int extra = 0}) => Expanded(
      child: Stack(
        fit: StackFit.expand,
        children: [
          MediaThumb(media: media[i], radius: 0, onTap: () => _open(context, i), memCacheWidth: 600),
          if (extra > 0)
            IgnorePointer(
              child: Container(
                color: Colors.black45,
                alignment: Alignment.center,
                child: Text('+$extra', style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w800)),
              ),
            ),
        ],
      ),
    );
    final n = media.length;
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: height,
        child: switch (n) {
          1 => Row(children: [cell(0)]),
          2 => Row(children: [cell(0), const SizedBox(width: gap), cell(1)]),
          3 => Row(children: [
              cell(0),
              const SizedBox(width: gap),
              Expanded(child: Column(children: [cell(1), const SizedBox(height: gap), cell(2)])),
            ]),
          _ => Row(children: [
              cell(0),
              const SizedBox(width: gap),
              Expanded(
                child: Column(children: [
                  cell(1),
                  const SizedBox(height: gap),
                  Expanded(child: Row(children: [cell(2), const SizedBox(width: gap), cell(3, extra: n - 4)])),
                ]),
              ),
            ]),
        },
      ),
    );
  }
}
