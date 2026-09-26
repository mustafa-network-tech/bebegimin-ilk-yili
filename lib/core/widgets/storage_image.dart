import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/signed_urls.dart';

/// Displays an object from a PRIVATE bucket through a signed URL.
/// The disk cache is keyed by bucket/path, so images seen once are
/// available offline even though signed URLs change.
class StorageImage extends ConsumerStatefulWidget {
  const StorageImage({
    super.key,
    required this.bucket,
    required this.path,
    this.fit = BoxFit.cover,
    this.placeholderIcon = Icons.photo_outlined,
    this.memCacheWidth,
  });

  final String bucket;
  final String? path;
  final BoxFit fit;
  final IconData placeholderIcon;
  final int? memCacheWidth;

  @override
  ConsumerState<StorageImage> createState() => _StorageImageState();
}

class _StorageImageState extends ConsumerState<StorageImage> {
  Future<String>? _url;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(covariant StorageImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path || oldWidget.bucket != widget.bucket) _resolve();
  }

  void _resolve() {
    final path = widget.path;
    _url = path == null ? null : ref.read(signedUrlCacheProvider).url(widget.bucket, path);
  }

  @override
  Widget build(BuildContext context) {
    final path = widget.path;
    if (path == null) return _Placeholder(icon: widget.placeholderIcon);
    final cacheKey = SignedUrlCache.cacheKey(widget.bucket, path);
    return FutureBuilder<String>(
      future: _url,
      builder: (context, snap) {
        // Even without a signed URL (offline) the cache key may still hit.
        final url = snap.data ?? 'https://offline.invalid/$cacheKey';
        if (snap.connectionState == ConnectionState.waiting && snap.data == null) {
          return _Placeholder(icon: widget.placeholderIcon, loading: true);
        }
        return CachedNetworkImage(
          imageUrl: url,
          cacheKey: cacheKey,
          fit: widget.fit,
          memCacheWidth: widget.memCacheWidth,
          fadeInDuration: const Duration(milliseconds: 180),
          placeholder: (_, _) => _Placeholder(icon: widget.placeholderIcon, loading: true),
          errorWidget: (_, _, _) => _Placeholder(icon: widget.placeholderIcon),
        );
      },
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({required this.icon, this.loading = false});

  final IconData icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surfaceContainerHigh,
      alignment: Alignment.center,
      child: loading
          ? SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2, color: scheme.primary.withValues(alpha: 0.5)),
            )
          : Icon(icon, color: scheme.onSurfaceVariant.withValues(alpha: 0.5)),
    );
  }
}
