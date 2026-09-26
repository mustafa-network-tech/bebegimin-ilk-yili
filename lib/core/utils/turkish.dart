/// Turkish grammar helpers (vowel harmony) used for personalised texts:
/// "Defne'nin kitabı", "Can'ın kitabı", "Ege'ye mektup", "Can'a mektup".
abstract final class Turkish {
  static const _vowels = 'aıoueiöü';
  static const _back = 'aıou';

  static String _lower(String s) => s
      .replaceAll('I', 'ı')
      .replaceAll('İ', 'i')
      .replaceAll('Ö', 'ö')
      .replaceAll('Ü', 'ü')
      .replaceAll('Ç', 'ç')
      .replaceAll('Ş', 'ş')
      .replaceAll('Ğ', 'ğ')
      .toLowerCase();

  static String? _lastVowel(String lower) {
    for (var i = lower.length - 1; i >= 0; i--) {
      if (_vowels.contains(lower[i])) return lower[i];
    }
    return null;
  }

  /// Defne → Defne'nin, Can → Can'ın, Umut → Umut'un, Öykü → Öykü'nün
  static String genitive(String name) {
    final n = name.trim();
    if (n.isEmpty) return n;
    final lower = _lower(n);
    final v = _lastVowel(lower) ?? 'e';
    final buffer = _vowels.contains(lower[lower.length - 1]) ? 'n' : '';
    final suffixVowel = switch (v) {
      'a' || 'ı' => 'ı',
      'e' || 'i' => 'i',
      'o' || 'u' => 'u',
      _ => 'ü',
    };
    return "$n'$buffer${suffixVowel}n";
  }

  /// Ege → Ege'ye, Can → Can'a, Defne → Defne'ye
  static String dative(String name) {
    final n = name.trim();
    if (n.isEmpty) return n;
    final lower = _lower(n);
    final v = _lastVowel(lower) ?? 'e';
    final buffer = _vowels.contains(lower[lower.length - 1]) ? 'y' : '';
    return "$n'$buffer${_back.contains(v) ? 'a' : 'e'}";
  }

  /// Turkish-aware upper case (i → İ, ı → I).
  static String upper(String s) =>
      s.replaceAll('i', 'İ').replaceAll('ı', 'I').toUpperCase();

  /// Turkish-aware, accent-insensitive folding used for client-side search.
  static String fold(String s) => _lower(s)
      .replaceAll('ı', 'i')
      .replaceAll('ö', 'o')
      .replaceAll('ü', 'u')
      .replaceAll('ç', 'c')
      .replaceAll('ş', 's')
      .replaceAll('ğ', 'g');
}
