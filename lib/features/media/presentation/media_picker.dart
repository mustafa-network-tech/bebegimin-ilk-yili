import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../../app/env.dart';
import '../../../core/widgets/feedback.dart';
import '../data/image_processing.dart';
import '../data/upload_queue.dart';
import '../domain/media_item.dart';

enum PickSource { cameraPhoto, galleryPhotos, cameraVideo, galleryVideo }

/// Camera / gallery picker for photos (single or multiple) and videos.
abstract final class MediaPicker {
  static final _picker = ImagePicker();

  static Future<List<PickedMedia>> pick(BuildContext context, PickSource source) async {
    try {
      switch (source) {
        case PickSource.cameraPhoto:
          final x = await _picker.pickImage(source: ImageSource.camera, requestFullMetadata: false);
          return x == null ? const [] : [PickedMedia(path: x.path, kind: MediaKind.photo)];
        case PickSource.galleryPhotos:
          final xs = await _picker.pickMultiImage(requestFullMetadata: false, limit: 30);
          return [for (final x in xs) PickedMedia(path: x.path, kind: MediaKind.photo)];
        case PickSource.cameraVideo:
        case PickSource.galleryVideo:
          final x = await _picker.pickVideo(
            source: source == PickSource.cameraVideo ? ImageSource.camera : ImageSource.gallery,
            maxDuration: const Duration(minutes: 5),
          );
          if (x == null) return const [];
          final size = await x.length();
          if (size > Env.maxVideoMb * 1024 * 1024) {
            if (context.mounted) showSnack(context, 'Video en fazla ${Env.maxVideoMb} MB olabilir.', error: true);
            return const [];
          }
          return [PickedMedia(path: x.path, kind: MediaKind.video)];
      }
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'Kameraya / galeriye erişilemedi. Uygulama izinlerini kontrol edin.', error: true);
      }
      return const [];
    }
  }

  /// Bottom sheet asking where to pick from.
  static Future<List<PickedMedia>> choose(BuildContext context, {bool photos = true, bool videos = true}) async {
    final source = await showModalBottomSheet<PickSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (photos) ...[
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Fotoğraf çek'),
                onTap: () => Navigator.pop(ctx, PickSource.cameraPhoto),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('Galeriden fotoğraf seç'),
                subtitle: const Text('Birden fazla seçebilirsiniz'),
                onTap: () => Navigator.pop(ctx, PickSource.galleryPhotos),
              ),
            ],
            if (videos) ...[
              ListTile(
                leading: const Icon(Icons.videocam_outlined),
                title: const Text('Video çek'),
                onTap: () => Navigator.pop(ctx, PickSource.cameraVideo),
              ),
              ListTile(
                leading: const Icon(Icons.video_library_outlined),
                title: const Text('Galeriden video seç'),
                onTap: () => Navigator.pop(ctx, PickSource.galleryVideo),
              ),
            ],
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (source == null || !context.mounted) return const [];
    return pick(context, source);
  }

  /// Single photo for avatars / covers / capsules.
  static Future<String?> singlePhoto(BuildContext context) async {
    final res = await choose(context, videos: false);
    return res.isEmpty ? null : res.first.path;
  }
}

/// Picks one photo and returns a compressed JPEG file (avatars, covers,
/// capsule photos). EXIF (location!) is stripped.
Future<File?> pickCompressedPhoto(BuildContext context, {int shortSide = 1200}) async {
  final path = await MediaPicker.singlePhoto(context);
  if (path == null) return null;
  final dir = await getTemporaryDirectory();
  return ImageProcessing.compressToFile(
    path,
    '${dir.path}/pick-${DateTime.now().millisecondsSinceEpoch}.jpg',
    shortSide,
    88,
  );
}
