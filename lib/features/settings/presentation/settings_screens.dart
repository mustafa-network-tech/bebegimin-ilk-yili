import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/env.dart';
import '../../../core/cache/local_cache.dart';
import '../../../core/storage/signed_urls.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/section_header.dart';
import '../../../core/widgets/states.dart';
import '../../admin/application/admin_providers.dart';
import '../../auth/data/auth_repository.dart';
import '../../babies/application/baby_providers.dart';
import '../../media/presentation/media_picker.dart';
import '../../notifications/data/push_service.dart';
import '../../profile/data/profile_repository.dart';
import '../../profile/domain/profile.dart';
import '../application/theme_mode.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    final ok = await confirm(
      context,
      title: 'Çıkış yapılsın mı?',
      message: 'Bu cihazdaki önbellek temizlenir.',
      confirmLabel: 'Çıkış yap',
    );
    if (!ok) return;
    await ref.read(pushServiceProvider).unregister();
    await ref.read(localCacheProvider).clear();
    ref.read(signedUrlCacheProvider).clear();
    await ref.read(activeBabyIdProvider.notifier).select(null);
    await ref.read(authRepositoryProvider).signOut();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider).value;
    final user = ref.watch(currentUserProvider);
    final mode = ref.watch(themeModeProvider);
    final babies = ref.watch(babiesProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(title: const Text('Ayarlar')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            leading: AppAvatar(name: profile?.displayName ?? '?', path: profile?.avatarPath, radius: 26),
            title: Text(profile?.displayName ?? '', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
            subtitle: Text(user?.email ?? ''),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => context.push('/settings/profile'),
          ),
          const SectionHeader(title: 'Çocuklarım'),
          for (final b in babies)
            ListTile(
              leading: AppAvatar(name: b.firstName, bucket: Buckets.babyMedia, path: b.avatarPath),
              title: Text(b.fullName),
              subtitle: Text(b.ageToday().label),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/baby/${b.id}/edit'),
            ),
          ListTile(
            leading: const Icon(Icons.add_rounded),
            title: const Text('Yeni çocuk ekle'),
            onTap: () => context.push('/baby/new'),
          ),
          ListTile(
            leading: const Icon(Icons.vpn_key_outlined),
            title: const Text('Davet koduyla katıl'),
            onTap: () => context.push('/join'),
          ),
          if (ref.watch(adminSessionProvider).value?.isSuperAdmin ?? false) ...[
            const SectionHeader(title: 'Platform'),
            ListTile(
              leading: const Icon(Icons.admin_panel_settings_outlined),
              title: const Text('Platform yönetimi'),
              subtitle: const Text('Uzatma talepleri, doğum tarihi düzeltmeleri, denetim kaydı'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => context.push('/admin'),
            ),
          ],
          const SectionHeader(title: 'Görünüm'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('Sistem'),
                  icon: Icon(Icons.brightness_auto_outlined),
                ),
                ButtonSegment(value: ThemeMode.light, label: Text('Açık'), icon: Icon(Icons.light_mode_outlined)),
                ButtonSegment(value: ThemeMode.dark, label: Text('Koyu'), icon: Icon(Icons.dark_mode_outlined)),
              ],
              selected: {mode},
              onSelectionChanged: (s) => ref.read(themeModeProvider.notifier).set(s.first),
            ),
          ),
          const SectionHeader(title: 'Hesap ve gizlilik'),
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('Bildirimler'),
            onTap: () => context.push('/settings/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.password_rounded),
            title: const Text('Şifre değiştir'),
            onTap: () => context.push('/settings/password'),
          ),
          ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: const Text('Gizlilik ve veri güvenliği'),
            onTap: () => context.push('/settings/privacy'),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('Önbelleği temizle'),
            subtitle: const Text('Çevrimdışı için saklanan veriler silinir'),
            onTap: () async {
              await ref.read(localCacheProvider).clear();
              ref.read(signedUrlCacheProvider).clear();
              if (context.mounted) showSnack(context, 'Önbellek temizlendi');
            },
          ),
          ListTile(
            leading: const Icon(Icons.logout_rounded),
            title: const Text('Çıkış yap'),
            onTap: () => _signOut(context, ref),
          ),
          ListTile(
            leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
            title: Text('Hesabımı sil', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () => context.push('/settings/delete-account'),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              'Bebeğimin İlk Yılı · v0.1.0${Env.demoMode ? ' · DEMO' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: ref.read(myProfileProvider).value?.displayName ?? '');
  File? _avatar;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save(Profile? profile) async {
    if (!_form.currentState!.validate()) return;
    final uid = ref.read(currentUserIdProvider)!;
    setState(() => _busy = true);
    try {
      final repo = ref.read(profileRepositoryProvider);
      if (_avatar != null) await repo.uploadAvatar(uid, _avatar!, previousPath: profile?.avatarPath);
      await repo.update(uid, displayName: _name.text);
      ref.invalidate(myProfileProvider);
      if (mounted) {
        showSnack(context, 'Profil güncellendi');
        context.pop();
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(myProfileProvider).value;
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Center(
              child: GestureDetector(
                onTap: () async {
                  final f = await pickCompressedPhoto(context, shortSide: 600);
                  if (f != null) setState(() => _avatar = f);
                },
                child: Stack(
                  children: [
                    _avatar != null
                        ? CircleAvatar(radius: 48, backgroundImage: FileImage(_avatar!))
                        : AppAvatar(name: profile?.displayName ?? '?', path: profile?.avatarPath, radius: 48),
                    const Positioned(
                      right: 0,
                      bottom: 0,
                      child: CircleAvatar(radius: 16, child: Icon(Icons.edit, size: 16)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Adınız'),
              validator: (v) => Validators.required(v, field: 'Ad') ?? Validators.maxLength(v, 80),
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _busy ? null : () => _save(profile), child: const Text('Kaydet')),
          ],
        ),
      ),
    );
  }
}

class ChangePasswordScreen extends ConsumerStatefulWidget {
  const ChangePasswordScreen({super.key});

  @override
  ConsumerState<ChangePasswordScreen> createState() => _ChangePasswordScreenState();
}

class _ChangePasswordScreenState extends ConsumerState<ChangePasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Şifre değiştir')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextFormField(
              controller: _p1,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Yeni şifre'),
              validator: Validators.password,
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _p2,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Yeni şifre (tekrar)'),
              validator: (v) => v != _p1.text ? 'Şifreler eşleşmiyor' : null,
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () async {
                      if (!_form.currentState!.validate()) return;
                      setState(() => _busy = true);
                      try {
                        await ref.read(authRepositoryProvider).updatePassword(_p1.text);
                        if (context.mounted) {
                          showSnack(context, 'Şifreniz güncellendi');
                          context.pop();
                        }
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      } finally {
                        if (mounted) setState(() => _busy = false);
                      }
                    },
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }
}

class NotificationSettingsScreen extends ConsumerWidget {
  const NotificationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider);
    final push = ref.watch(pushServiceProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Bildirimler')),
      body: AsyncValueView<Profile?>(
        value: profile,
        onRetry: () => ref.invalidate(myProfileProvider),
        data: (p) => ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                push.isAvailable ? 'Bildirimler uygulama içinde ve telefonunuza anlık bildirim olarak gelir.' : 'Bildirimler uygulama içindeki kutuda görünür. Anlık (push) bildirimler bu sürümde yapılandırılmamış.',
              ),
            ),
            for (final e in NotificationPrefKeys.labels.entries)
              SwitchListTile(
                title: Text(e.value),
                value: p?.pref(e.key) ?? true,
                onChanged: p == null
                    ? null
                    : (v) async {
                        final prefs = {...p.notificationPrefs, e.key: v};
                        try {
                          await ref.read(profileRepositoryProvider).update(p.id, notificationPrefs: prefs);
                          ref.invalidate(myProfileProvider);
                        } catch (err) {
                          if (context.mounted) showError(context, err);
                        }
                      },
              ),
          ],
        ),
      ),
    );
  }
}

class DeleteAccountScreen extends ConsumerStatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  ConsumerState<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends ConsumerState<DeleteAccountScreen> {
  bool _deleteContent = false;
  final _confirm = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Hesabımı sil')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text('Hesabınız kalıcı olarak silinecek.', style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
            '• Tek üyesi olduğunuz bebek arşivleri, tüm fotoğraf ve videolarıyla silinir.\n'
            '• Başka aile üyeleriyle paylaştığınız arşivlerde, son yöneticiyseniz en eski üye yönetici yapılır.\n'
            '• Paylaşılan arşivlere eklediğiniz anılar varsayılan olarak ailede kalır (yazar bilgisi kaldırılır).',
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _deleteContent,
            onChanged: (v) => setState(() => _deleteContent = v ?? false),
            title: const Text('Paylaşılan arşivlere eklediğim tüm anı, fotoğraf, video, mektup ve yorumları da sil'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            decoration: const InputDecoration(labelText: 'Onay için SİL yazın'),
          ),
          const SizedBox(height: 20),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            onPressed: _busy
                ? null
                : () async {
                    if (_confirm.text.trim().toUpperCase() != 'SİL' && _confirm.text.trim().toUpperCase() != 'SIL') {
                      showSnack(context, 'Onay için SİL yazın.', error: true);
                      return;
                    }
                    setState(() => _busy = true);
                    try {
                      await ref.read(pushServiceProvider).unregister();
                      await ref.read(authRepositoryProvider).deleteAccount(deleteMyContent: _deleteContent);
                      await ref.read(localCacheProvider).clear();
                    } catch (e) {
                      if (context.mounted) showError(context, e);
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: const Text('Hesabımı kalıcı olarak sil'),
          ),
        ],
      ),
    );
  }
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget item(IconData icon, String title, String text) => ListTile(
      leading: Icon(icon, color: theme.colorScheme.primary),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(text),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Gizlilik')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          item(
            Icons.lock_outline_rounded,
            'Varsayılan olarak özel',
            'Hiçbir bebek profili, fotoğraf ya da anı herkese açık değildir ve arama motorlarında görünmez.',
          ),
          item(
            Icons.family_restroom_rounded,
            'Yalnızca davet ettiğiniz aile',
            'İçeriklere yalnızca davet kodunu kabul eden aile üyeleri, verilen yetkiler kadar erişebilir. Yetkiler sunucuda (veritabanı güvenlik politikalarıyla) denetlenir.',
          ),
          item(
            Icons.cloud_done_outlined,
            'Özel dosya depolama',
            'Fotoğraf ve videolar herkese açık bağlantılarla değil, bir saat geçerli imzalı bağlantılarla gösterilir.',
          ),
          item(
            Icons.location_off_outlined,
            'Konum bilgisi silinir',
            'Yüklenen fotoğrafların EXIF (konum dahil) bilgileri cihazda temizlenir.',
          ),
          item(
            Icons.hourglass_bottom_rounded,
            'Mühürlü zaman kapsülleri',
            'Zaman kapsülü içerikleri açılış tarihine kadar sunucudan hiç kimseye gönderilmez.',
          ),
          item(
            Icons.delete_outline_rounded,
            'Silme hakkı',
            'Hesabınızı, bebek arşivini ve tüm dosyaları istediğiniz zaman kalıcı olarak silebilirsiniz.',
          ),
        ],
      ),
    );
  }
}
