class Profile {
  const Profile({
    required this.id,
    required this.displayName,
    required this.avatarPath,
    required this.onboardingCompleted,
    required this.notificationPrefs,
  });

  factory Profile.fromJson(Map<String, dynamic> j) => Profile(
    id: j['id'] as String,
    displayName: j['display_name'] as String? ?? '',
    avatarPath: j['avatar_path'] as String?,
    onboardingCompleted: j['onboarding_completed'] as bool? ?? false,
    notificationPrefs: ((j['notification_prefs'] as Map?) ?? const {}).map(
      (k, v) => MapEntry(k.toString(), v == true),
    ),
  );

  final String id;
  final String displayName;
  final String? avatarPath;
  final bool onboardingCompleted;
  final Map<String, bool> notificationPrefs;

  Map<String, dynamic> toJson() => {
    'id': id,
    'display_name': displayName,
    'avatar_path': avatarPath,
    'onboarding_completed': onboardingCompleted,
    'notification_prefs': notificationPrefs,
  };

  bool get hasName => displayName.trim().isNotEmpty;

  bool pref(String key) => notificationPrefs[key] ?? true;
}

/// Keys of `profiles.notification_prefs`.
abstract final class NotificationPrefKeys {
  static const familyActivity = 'family_activity';
  static const anniversaries = 'anniversaries';
  static const memoriesOfTheDay = 'memories_of_the_day';
  static const book = 'book';
  static const timeCapsules = 'time_capsules';

  static const labels = {
    familyActivity: 'Aile etkinlikleri (yeni anı, ilk, mektup)',
    anniversaries: 'Ay dönümleri ve doğum günleri',
    memoriesOfTheDay: '"Bir yıl önce bugün" hatırlatmaları',
    book: 'İlk Yılım kitabı bildirimleri',
    timeCapsules: 'Zaman kapsülü açılışları',
  };
}
