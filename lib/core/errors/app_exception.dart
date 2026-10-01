import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

enum AppErrorKind { network, auth, permission, notFound, validation, conflict, server, unknown }

/// A user facing error with a Turkish message.
class AppException implements Exception {
  const AppException(this.message, {this.kind = AppErrorKind.unknown, this.cause});

  final String message;
  final AppErrorKind kind;
  final Object? cause;

  bool get isNetwork => kind == AppErrorKind.network;

  @override
  String toString() => message;

  /// Maps any error (Supabase, IO, …) to a friendly message.
  static AppException from(Object error) {
    if (error is AppException) return error;
    if (isNetworkError(error)) {
      return AppException(
        'İnternet bağlantısı kurulamadı. Bağlantınızı kontrol edip tekrar deneyin.',
        kind: AppErrorKind.network,
        cause: error,
      );
    }
    if (error is AuthException) return _fromAuth(error);
    if (error is PostgrestException) return _fromPostgrest(error);
    if (error is StorageException) return _fromStorage(error);
    if (error is FunctionException) {
      final details = error.details;
      final msg = details is Map && details['error'] is String ? details['error'] as String : null;
      return AppException(
        msg ?? 'Sunucu işlemi tamamlanamadı (${error.status}).',
        kind: AppErrorKind.server,
        cause: error,
      );
    }
    return AppException('Beklenmeyen bir hata oluştu. Lütfen tekrar deneyin.', cause: error);
  }

  static bool isNetworkError(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException ||
      error is HandshakeException ||
      (error is AuthRetryableFetchException) ||
      (error is StorageException && error.statusCode == null && error.message.contains('Socket'));

  static AppException _fromAuth(AuthException e) {
    final code = e.code ?? '';
    final msg = e.message.toLowerCase();
    String text;
    var kind = AppErrorKind.auth;
    if (code == 'invalid_credentials' || msg.contains('invalid login credentials')) {
      text = 'E-posta veya şifre hatalı.';
    } else if (code == 'email_not_confirmed' || msg.contains('email not confirmed')) {
      text = 'E-posta adresiniz henüz doğrulanmadı. Gelen kutunuzu kontrol edin.';
    } else if (code == 'user_already_exists' || msg.contains('already registered')) {
      text = 'Bu e-posta adresiyle zaten bir hesap var.';
      kind = AppErrorKind.conflict;
    } else if (code == 'weak_password' || msg.contains('password should')) {
      text = 'Şifre yeterince güçlü değil. En az 8 karakter, harf ve rakam kullanın.';
      kind = AppErrorKind.validation;
    } else if (code == 'over_email_send_rate_limit' || code == 'over_request_rate_limit' || e.statusCode == '429') {
      text = 'Çok fazla deneme yapıldı. Lütfen biraz sonra tekrar deneyin.';
    } else if (code == 'same_password') {
      text = 'Yeni şifre eskisiyle aynı olamaz.';
      kind = AppErrorKind.validation;
    } else if (code == 'session_expired' || code == 'refresh_token_not_found') {
      text = 'Oturumunuzun süresi doldu. Lütfen tekrar giriş yapın.';
    } else {
      text = 'Kimlik doğrulama hatası: ${e.message}';
    }
    return AppException(text, kind: kind, cause: e);
  }

  static const _hintMessages = <String, String>{
    'invitation_not_found': 'Davet kodu bulunamadı. Kodu kontrol edin.',
    'invitation_expired': 'Bu davetin süresi dolmuş. Aileden yeni bir davet isteyin.',
    'invitation_revoked': 'Bu davet iptal edilmiş.',
    'invitation_accepted': 'Bu davet daha önce kullanılmış.',
    'invitation_email_mismatch': 'Bu davet başka bir e-posta adresi için oluşturulmuş.',
    'already_member': 'Zaten bu ailenin bir üyesisiniz.',
    'last_admin': 'Ailenin en az bir yöneticisi olmalı. Önce başka bir üyeyi yönetici yapın.',
    'date_in_future': 'Gelecekteki bir tarih seçilemez.',
    'date_before_birth': 'Seçilen tarih doğum tarihinden çok önce.',
    'open_date_not_future': 'Açılış tarihi gelecekte olmalı.',
    'lifecycle_locked': 'İlk yıl arşivi tamamlandı ve kilitlendi. İçerikler artık yalnızca görüntülenebilir.',
    'birth_date_rpc_only': 'Doğum tarihi yalnızca doğum tarihi düzeltme adımıyla değiştirilebilir.',
    'birth_date_requires_admin':
        'İçerik eklendikten sonra doğum tarihi yalnızca destek ekibi tarafından düzeltilebilir.',
    'birth_date_reason_required': 'Doğum tarihi düzeltmesi için gerekçe yazın.',
    'reopen_confirmation_required': 'Kilitli profili yeniden açmak için açık onay gerekiyor.',
    'decision_note_required': 'Reddetmek için karar notu yazın.',
    'search_too_short': 'En az 2 karakter yazın.',
    'rate_limited': 'Çok fazla işlem yapıldı. Lütfen bir dakika sonra tekrar deneyin.',
    'admin_console_disabled': 'Yönetim paneli geçici olarak kapalı.',
    'family_capacity_full': 'Aile paketinin üye kapasitesi dolu. Katılım için Anne veya Baba paketi yükseltebilir ya da bir üyeyi çıkarabilir.',
    'parent_seats_full': 'Bu aile hesabında iki ebeveyn zaten kayıtlı.',
    'subscription_required': 'Bu işlem için aktif bir aile paketi gerekiyor.',
    'premium_requires_locked': 'Dijital ürünler ilk yıl arşivi tamamlandıktan sonra sunulur.',
    'storefront_closed': 'Dijital ürünler yakında satışta.',
    'already_owned': 'Bu ürün bu bebek için zaten satın alınmış.',
    'not_parent': 'Bu işlemi yalnızca Anne veya Baba yapabilir.',
    'purchase_not_yours': 'Bu satın alma başka bir aile hesabına ait.',
    'entitlement_required': 'Bu dijital ürün bu bebek için henüz satın alınmadı.',
    'book_renderer_disabled': 'Kitap oluşturma geçici olarak durduruldu. Lütfen daha sonra tekrar deneyin.',
    'book_render_in_progress': 'Kitap şu anda başka bir cihazda hazırlanıyor. Birkaç dakika sonra tekrar deneyin.',
    'book_project_missing': 'Önce kitap taslağını oluşturun.',
    'lease_lost': 'Kitap hazırlama süresi doldu. Lütfen tekrar deneyin.',
    'book_export_requires_artifact':
        'Uygulamanızı güncelleyin: kitaplar artık sunucuda doğrulanan resmî dosya olarak oluşturuluyor.',
    'film_too_long': 'Film 10 dakikayı aşıyor. Seçimi azaltın veya önerilen seçimi uygulayın.',
    'film_empty': 'Filme eklenecek içerik yok. Seçimi genişletin.',
    'film_renderer_disabled': 'Film hazırlama geçici olarak durduruldu. Lütfen daha sonra tekrar deneyin.',
    'film_render_in_progress': 'Film şu anda hazırlanıyor. Bitince tekrar deneyebilirsiniz.',
    'html_renderer_disabled': 'Arşiv hazırlama geçici olarak durduruldu. Lütfen daha sonra tekrar deneyin.',
    'html_render_in_progress': 'Arşiv şu anda hazırlanıyor. Bitince tekrar deneyebilirsiniz.',
    'member_not_found': 'Bu kişi bu bebeğin aile üyesi değil.',
    'family_account_ambiguous':
        'Birden fazla aile hesabınız var; bebeği hangi hesaba ekleyeceğinizi seçmeniz gerekiyor.',
  };

  /// Hints that describe a permanent server-side refusal rather than bad input.
  static const _permissionHints = {
    'lifecycle_locked',
    'birth_date_rpc_only',
    'birth_date_requires_admin',
    'reopen_confirmation_required',
    'rate_limited',
    'admin_console_disabled',
    'family_capacity_full',
    'parent_seats_full',
    'subscription_required',
    'premium_requires_locked',
    'storefront_closed',
    'already_owned',
    'not_parent',
    'purchase_not_yours',
    'entitlement_required',
    'book_renderer_disabled',
    'book_export_requires_artifact',
    'film_renderer_disabled',
    'html_renderer_disabled',
  };

  /// True when the server refused a write because the baby's archive is locked.
  static bool isLifecycleLocked(Object error) => error is PostgrestException && error.hint == 'lifecycle_locked';

  static AppException _fromPostgrest(PostgrestException e) {
    final hint = e.hint;
    if (hint != null && _hintMessages.containsKey(hint)) {
      final kind = hint == 'invitation_not_found'
          ? AppErrorKind.notFound
          : _permissionHints.contains(hint)
          ? AppErrorKind.permission
          : AppErrorKind.validation;
      return AppException(_hintMessages[hint]!, kind: kind, cause: e);
    }
    switch (e.code) {
      case '42501':
        return AppException('Bu işlem için yetkiniz yok.', kind: AppErrorKind.permission, cause: e);
      case '23505':
        return AppException('Bu kayıt zaten mevcut.', kind: AppErrorKind.conflict, cause: e);
      case '23503':
        return AppException('İlgili kayıt bulunamadı veya silinmiş.', kind: AppErrorKind.notFound, cause: e);
      case '23514':
      case '22023':
      case '22P02':
        return AppException('Girilen bilgiler geçersiz.', kind: AppErrorKind.validation, cause: e);
      case 'PGRST116':
        return AppException('Kayıt bulunamadı.', kind: AppErrorKind.notFound, cause: e);
      case 'P0002':
        return AppException('Kayıt bulunamadı.', kind: AppErrorKind.notFound, cause: e);
    }
    if (e.message.contains('row-level security')) {
      return AppException('Bu işlem için yetkiniz yok.', kind: AppErrorKind.permission, cause: e);
    }
    return AppException('Sunucu hatası: ${e.message}', kind: AppErrorKind.server, cause: e);
  }

  static AppException _fromStorage(StorageException e) {
    switch (e.statusCode) {
      case '413':
        return AppException('Dosya çok büyük.', kind: AppErrorKind.validation, cause: e);
      case '403':
      case '401':
        return AppException('Bu dosyaya erişim yetkiniz yok.', kind: AppErrorKind.permission, cause: e);
      case '404':
        return AppException('Dosya bulunamadı.', kind: AppErrorKind.notFound, cause: e);
      case '415':
        return AppException('Bu dosya türü desteklenmiyor.', kind: AppErrorKind.validation, cause: e);
    }
    return AppException('Dosya işlemi başarısız: ${e.message}', kind: AppErrorKind.server, cause: e);
  }
}
