import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/session.dart';
import '../../../core/supabase_providers.dart';
import '../../../core/utils/dates.dart';
import '../../../core/utils/validators.dart';
import '../../../core/widgets/feedback.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/presentation/auth_screens.dart';
import '../../family/application/family_providers.dart';
import '../../family/data/family_repository.dart';
import '../../family/domain/invitation.dart';
import '../../family/domain/relation.dart';
import '../../media/presentation/media_picker.dart';
import '../../profile/data/profile_repository.dart';
import '../application/baby_providers.dart';

/// First step after sign-up: how the family will see you.
class ProfileSetupScreen extends ConsumerStatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  ConsumerState<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends ConsumerState<ProfileSetupScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: ref.read(myProfileProvider).value?.displayName ?? '');
  File? _avatar;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final uid = ref.read(currentUserIdProvider)!;
    setState(() => _busy = true);
    try {
      final repo = ref.read(profileRepositoryProvider);
      if (_avatar != null) await repo.uploadAvatar(uid, _avatar!);
      await repo.update(uid, displayName: _name.text, onboardingCompleted: true);
      ref.invalidate(myProfileProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AuthScaffold(
      title: 'Profilinizi oluşturun',
      subtitle: 'Aileniz anıların altında adınızı ve fotoğrafınızı görecek.',
      children: [
        Center(
          child: GestureDetector(
            onTap: () async {
              final f = await pickCompressedPhoto(context, shortSide: 600);
              if (f != null) setState(() => _avatar = f);
            },
            child: CircleAvatar(
              radius: 48,
              backgroundColor: scheme.primary.withValues(alpha: 0.15),
              backgroundImage: _avatar == null ? null : FileImage(_avatar!),
              child: _avatar == null ? Icon(Icons.add_a_photo_outlined, color: scheme.primary, size: 30) : null,
            ),
          ),
        ),
        const SizedBox(height: 20),
        Form(
          key: _form,
          child: TextFormField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Adınız', prefixIcon: Icon(Icons.person_outline_rounded)),
            validator: (v) => Validators.required(v, field: 'Ad') ?? Validators.maxLength(v, 80),
          ),
        ),
        const SizedBox(height: 24),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Devam et')),
        TextButton(onPressed: () => ref.read(authRepositoryProvider).signOut(), child: const Text('Çıkış yap')),
      ],
    );
  }
}

/// No baby yet: create one or join an existing family.
class StartChoiceScreen extends ConsumerWidget {
  const StartChoiceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    Widget option(IconData icon, String title, String text, VoidCallback onTap) => Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              CircleAvatar(radius: 26, backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.14), child: Icon(icon, color: theme.colorScheme.primary)),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded),
            ],
          ),
        ),
      ),
    );

    return AuthScaffold(
      title: 'Hadi başlayalım',
      subtitle: 'Bebeğinizin dijital aile arşivi tamamen özeldir; yalnızca davet ettiğiniz kişiler görebilir.',
      children: [
        option(Icons.child_care_rounded, 'Bebek profili oluştur', 'Yeni bir arşiv başlatın, aile üyelerinizi davet edin.',
            () => context.push('/baby/new')),
        const SizedBox(height: 12),
        option(Icons.vpn_key_outlined, 'Davet koduyla katıl', 'Bir aile üyeniz size kod veya bağlantı gönderdiyse.',
            () => context.push('/join')),
        const SizedBox(height: 24),
        TextButton(onPressed: () => ref.read(authRepositoryProvider).signOut(), child: const Text('Çıkış yap')),
      ],
    );
  }
}

class JoinFamilyScreen extends ConsumerStatefulWidget {
  const JoinFamilyScreen({super.key, this.initialCode});

  final String? initialCode;

  @override
  ConsumerState<JoinFamilyScreen> createState() => _JoinFamilyScreenState();
}

class _JoinFamilyScreenState extends ConsumerState<JoinFamilyScreen> {
  late final _code = TextEditingController(text: widget.initialCode ?? ref.read(pendingInviteCodeProvider) ?? '');
  InvitationPreview? _preview;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (InviteCode.isValid(_code.text)) WidgetsBinding.instance.addPostFrameCallback((_) => _lookup());
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final code = InviteCode.parse(_code.text);
    if (code == null) {
      setState(() => _error = 'Kod 10 karakter olmalı (ör. ABCDE-23456).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final p = await ref.read(familyRepositoryProvider).preview(code);
      setState(() {
        _preview = p;
        _error = p == null ? 'Bu kod geçersiz, süresi dolmuş ya da iptal edilmiş.' : null;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    final code = InviteCode.parse(_code.text)!;
    setState(() => _busy = true);
    try {
      final babyId = await ref.read(familyRepositoryProvider).accept(code);
      ref.read(pendingInviteCodeProvider.notifier).set(null);
      await ref.read(activeBabyIdProvider.notifier).select(babyId);
      ref.invalidate(babiesProvider);
      ref.invalidate(membersProvider(babyId));
      if (mounted) {
        showSnack(context, 'Aileye katıldınız 🤍');
        context.go('/home');
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _preview;
    return AuthScaffold(
      showBack: true,
      title: 'Aileye katıl',
      subtitle: 'Size gönderilen 10 karakterlik davet kodunu girin.',
      children: [
        TextField(
          controller: _code,
          textCapitalization: TextCapitalization.characters,
          maxLength: 11,
          style: const TextStyle(fontSize: 22, letterSpacing: 3, fontWeight: FontWeight.w800),
          decoration: InputDecoration(labelText: 'Davet kodu', errorText: _error, counterText: ''),
          onChanged: (_) => setState(() => _preview = null),
          onSubmitted: (_) => _lookup(),
        ),
        const SizedBox(height: 16),
        if (p == null)
          FilledButton(onPressed: _busy ? null : _lookup, child: const Text('Kodu kontrol et'))
        else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${p.inviterName} sizi ${p.babyFirstName} için aileye davet ediyor.',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('Rolünüz: ${relationText(p.relation, p.relationLabel)}'),
                  Text('Son geçerlilik: ${Dates.long(p.expiresAt.toLocal())}'),
                  if (p.alreadyMember) ...[
                    const SizedBox(height: 8),
                    const Text('Zaten bu ailenin üyesisiniz.', style: TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy || p.alreadyMember ? null : _accept, child: const Text('Daveti kabul et')),
        ],
      ],
    );
  }
}
