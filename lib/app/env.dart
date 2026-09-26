/// Build-time configuration, injected with
///   flutter run --dart-define-from-file=env/dev.json
/// Never put the Supabase *service role* key here – only the public
/// anon / publishable key belongs in a mobile app.
abstract final class Env {
  static const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Redirect used in auth e-mails (verification / password reset).
  static const authRedirectUrl = String.fromEnvironment(
    'AUTH_REDIRECT_URL',
    defaultValue: 'bebegimin://login-callback',
  );

  /// Base for shareable invitation links. With the default custom scheme
  /// the link opens the app directly; set an https URL once App Links /
  /// Universal Links are configured.
  static const inviteLinkBase = String.fromEnvironment('INVITE_LINK_BASE', defaultValue: 'bebegimin://invite');

  /// Shows demo account shortcuts on the login screen. Only for local
  /// development against `supabase db reset` + seed.sql.
  static const demoMode = bool.fromEnvironment('DEMO_MODE');

  static const maxVideoMb = int.fromEnvironment('MAX_VIDEO_MB', defaultValue: 200);

  // Optional Firebase Cloud Messaging (push). Leave empty to disable push;
  // in-app notifications keep working.
  static const firebaseApiKey = String.fromEnvironment('FIREBASE_API_KEY');
  static const firebaseProjectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  static const firebaseSenderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  static const firebaseAndroidAppId = String.fromEnvironment('FIREBASE_ANDROID_APP_ID');
  static const firebaseIosAppId = String.fromEnvironment('FIREBASE_IOS_APP_ID');
  static const firebaseIosBundleId = String.fromEnvironment('FIREBASE_IOS_BUNDLE_ID');

  static bool get isSupabaseConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get isPushConfigured =>
      firebaseApiKey.isNotEmpty && firebaseProjectId.isNotEmpty && firebaseSenderId.isNotEmpty;
}
