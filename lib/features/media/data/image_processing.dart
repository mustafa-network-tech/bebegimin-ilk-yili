import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

class ProcessedPhoto {
  const ProcessedPhoto({required this.original, required this.thumb, required this.width, required this.height});

  final File original;
  final File thumb;
  final int width;
  final int height;
}

/// Photo pipeline used before uploading:
///  * EXIF orientation applied, EXIF metadata (GPS!) stripped,
///  * converted to JPEG (HEIC/PNG supported as input),
///  * "original" limited to a 2560 px short side (print quality),
///  * 480 px thumbnail for grids.
/// Runs natively (platform threads), so the UI isolate stays responsive.
abstract final class ImageProcessing {
  static const originalShortSide = 2560;
  static const thumbShortSide = 480;

  static Future<ProcessedPhoto> processPhoto(String sourcePath, String outDir, String id) async {
    final original = await compressToFile(sourcePath, '$outDir/${id}_original.jpg', originalShortSide, 90);
    final thumb = await compressToFile(original.path, '$outDir/${id}_thumb.jpg', thumbShortSide, 78);
    final (w, h) = await imageSize(original);
    return ProcessedPhoto(original: original, thumb: thumb, width: w, height: h);
  }

  static Future<File> compressToFile(String source, String target, int shortSide, int quality) async {
    final result = await FlutterImageCompress.compressAndGetFile(
      source,
      target,
      minWidth: shortSide,
      minHeight: shortSide,
      quality: quality,
      format: CompressFormat.jpeg,
      keepExif: false,
      autoCorrectionAngle: true,
    );
    if (result == null) throw const FileSystemException('Fotoğraf işlenemedi');
    return File(result.path);
  }

  /// Compresses bytes in memory (book generation).
  static Future<Uint8List> compressBytes(Uint8List bytes, int shortSide, int quality) =>
      FlutterImageCompress.compressWithList(
        bytes,
        minWidth: shortSide,
        minHeight: shortSide,
        quality: quality,
        format: CompressFormat.jpeg,
        keepExif: false,
      );

  /// Reads only the header – no full decode.
  static Future<(int, int)> imageSize(File file) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(await file.readAsBytes());
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    final size = (descriptor.width, descriptor.height);
    descriptor.dispose();
    buffer.dispose();
    return size;
  }

  static String mimeForVideo(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.mov')) return 'video/quicktime';
    if (p.endsWith('.3gp')) return 'video/3gpp';
    if (p.endsWith('.webm')) return 'video/webm';
    if (p.endsWith('.m4v')) return 'video/x-m4v';
    return 'video/mp4';
  }

  static String extensionFor(String mime) => switch (mime) {
    'video/quicktime' => 'mov',
    'video/3gpp' => '3gp',
    'video/webm' => 'webm',
    'video/x-m4v' => 'm4v',
    'video/mp4' => 'mp4',
    _ => 'jpg',
  };
}
