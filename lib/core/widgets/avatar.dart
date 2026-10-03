import 'package:flutter/material.dart';

import '../storage/signed_urls.dart';
import 'storage_image.dart';

class AppAvatar extends StatelessWidget {
  const AppAvatar({
    super.key,
    required this.name,
    this.bucket = Buckets.avatars,
    this.path,
    this.radius = 20,
    this.color,
  });

  final String name;
  final String bucket;
  final String? path;
  final double radius;
  final Color? color;

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    final first = parts.first.characters.first;
    final last = parts.length > 1 ? parts.last.characters.first : '';
    return (first + last).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = color ?? scheme.primary.withValues(alpha: 0.16);
    return SizedBox.square(
      dimension: radius * 2,
      child: ClipOval(
        child: path == null
            ? Container(
                color: bg,
                alignment: Alignment.center,
                child: Text(
                  _initials,
                  style: TextStyle(fontWeight: FontWeight.w800, fontSize: radius * 0.75, color: scheme.primary),
                ),
              )
            : StorageImage(
                bucket: bucket,
                path: path,
                placeholderIcon: Icons.person_outline,
                memCacheWidth: (radius * 6).round(),
              ),
      ),
    );
  }
}
