import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../errors/app_exception.dart';

/// Downloads a premium output artifact through a fresh 60-second grant
/// (`output-download`) and checks the bytes against its SHA-256.
Future<Uint8List> downloadVerifiedArtifact(SupabaseClient client, String artifactId, String expectedSha256) async {
  final res = await client.functions.invoke('output-download', body: {'artifact_id': artifactId});
  final grant = (res.data as Map).cast<String, dynamic>();
  final response = await http.get(Uri.parse(grant['url'] as String));
  if (response.statusCode != 200) {
    throw AppException('Dosya indirilemedi (${response.statusCode}).', kind: AppErrorKind.server);
  }
  final bytes = response.bodyBytes;
  if (sha256.convert(bytes).toString() != expectedSha256) {
    throw const AppException('İndirilen dosya doğrulanamadı. Lütfen tekrar deneyin.', kind: AppErrorKind.server);
  }
  return bytes;
}
