abstract final class Validators {
  static final _email = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  static String? email(String? v) {
    final s = v?.trim() ?? '';
    if (s.isEmpty) return 'E-posta adresi gerekli';
    if (!_email.hasMatch(s)) return 'Geçerli bir e-posta adresi girin';
    return null;
  }

  static String? optionalEmail(String? v) => (v == null || v.trim().isEmpty) ? null : email(v);

  static String? password(String? v) {
    final s = v ?? '';
    if (s.length < 8) return 'Şifre en az 8 karakter olmalı';
    if (!RegExp(r'[A-Za-zÇĞİÖŞÜçğıöşü]').hasMatch(s) || !RegExp(r'\d').hasMatch(s)) {
      return 'Şifre harf ve rakam içermeli';
    }
    return null;
  }

  static String? required(String? v, {String field = 'Bu alan'}) =>
      (v == null || v.trim().isEmpty) ? '$field gerekli' : null;

  static String? maxLength(String? v, int max) => (v != null && v.length > max) ? 'En fazla $max karakter' : null;
}
