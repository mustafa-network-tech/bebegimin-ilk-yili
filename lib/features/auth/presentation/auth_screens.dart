import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/env.dart';
import '../../../app/session.dart';
import '../../../app/theme.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/utils/validators.dart';
import '../data/auth_repository.dart';

/// Shared warm layout for the auth flow.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.title, this.subtitle, required this.children, this.showBack = false});

  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool showBack;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: showBack ? AppBar() : null,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (!showBack) ...[const SizedBox(height: 12), const AppLogo(), const SizedBox(height: 28)],
                  Text(title, style: theme.textTheme.headlineMedium),
                  if (subtitle != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: 28),
                  ...children,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AppLogo extends StatelessWidget {
  const AppLogo({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppColors.apricotLight, AppColors.apricot],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(size * 0.32),
          ),
          child: Icon(Icons.favorite_rounded, color: Colors.white, size: size * 0.46),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Text('Bebeğimin\nİlk Yılı', style: Theme.of(context).textTheme.headlineSmall?.copyWith(height: 1.1)),
        ),
      ],
    );
  }
}

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) => const Scaffold(
    body: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 230, child: AppLogo()),
          SizedBox(height: 32),
          SizedBox.square(dimension: 28, child: CircularProgressIndicator(strokeWidth: 3)),
        ],
      ),
    ),
  );
}

class ConfigErrorScreen extends StatelessWidget {
  const ConfigErrorScreen({super.key});

  @override
  Widget build(BuildContext context) => const AuthScaffold(
    title: 'Yapılandırma eksik',
    subtitle: 'Uygulama bir Supabase projesine bağlı değil.',
    children: [
      Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SelectableText(
            'Uygulamayı şu komutla çalıştırın:\n\n'
            'flutter run --dart-define-from-file=env/dev.json\n\n'
            'env/example.json dosyasını env/dev.json olarak kopyalayıp '
            'SUPABASE_URL ve SUPABASE_ANON_KEY değerlerini doldurun. '
            'Ayrıntılar README.md dosyasında.',
          ),
        ),
      ),
    ],
  );
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(authRepositoryProvider).signIn(email: _email.text, password: _password.text);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = ref.watch(pendingInviteCodeProvider);
    return AuthScaffold(
      title: 'Tekrar hoş geldiniz',
      subtitle: pending != null
          ? 'Aileye katılmak için önce giriş yapın ya da hesap oluşturun.'
          : 'Ailenizin en değerli anıları sizi bekliyor.',
      children: [
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              children: [
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'E-posta', prefixIcon: Icon(Icons.mail_outline_rounded)),
                  validator: Validators.email,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Şifre',
                    prefixIcon: const Icon(Icons.lock_outline_rounded),
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Şifreyi göster' : 'Şifreyi gizle',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) => (v == null || v.isEmpty) ? 'Şifre gerekli' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: () => context.push('/forgot-password'), child: const Text('Şifremi unuttum')),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Text('Giriş yap'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: () => context.push('/register'), child: const Text('Yeni hesap oluştur')),
        if (Env.demoMode) ...[
          const SizedBox(height: 28),
          const Divider(),
          Text('Demo hesapları (yalnızca yerel geliştirme)', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (label, mail) in [
                ('Anne · Elif', 'anne@example.com'),
                ('Baba · Mert', 'baba@example.com'),
                ('Teyze · Zeynep', 'teyze@example.com'),
                ('Başka aile', 'baska@example.com'),
              ])
                ActionChip(
                  label: Text(label),
                  onPressed: () {
                    _email.text = mail;
                    _password.text = 'Demo1234!';
                    _submit();
                  },
                ),
            ],
          ),
        ],
      ],
    );
  }
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  bool _accepted = false;
  bool _busy = false;

  @override
  void dispose() {
    for (final c in [_name, _email, _password, _password2]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_accepted) {
      showSnack(context, 'Devam etmek için gizlilik ilkelerini onaylayın.', error: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final signedIn = await ref
          .read(authRepositoryProvider)
          .signUp(email: _email.text, password: _password.text, displayName: _name.text);
      if (!mounted) return;
      if (!signedIn) context.go('/verify-email?email=${Uri.encodeComponent(_email.text.trim())}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      showBack: true,
      title: 'Hesap oluşturun',
      subtitle: 'Aile üyeleriniz sizi bu isimle görecek.',
      children: [
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              children: [
                TextFormField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(
                    labelText: 'Adınız',
                    prefixIcon: Icon(Icons.person_outline_rounded),
                  ),
                  validator: (v) => Validators.required(v, field: 'Ad') ?? Validators.maxLength(v, 80),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(labelText: 'E-posta', prefixIcon: Icon(Icons.mail_outline_rounded)),
                  validator: Validators.email,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(
                    labelText: 'Şifre',
                    helperText: 'En az 8 karakter, harf ve rakam',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                  validator: Validators.password,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _password2,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Şifre (tekrar)',
                    prefixIcon: Icon(Icons.lock_outline_rounded),
                  ),
                  validator: (v) => v != _password.text ? 'Şifreler eşleşmiyor' : null,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _accepted,
          onChanged: (v) => setState(() => _accepted = v ?? false),
          controlAffinity: ListTileControlAffinity.leading,
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Paylaştığım içeriklerin yalnızca davet ettiğim aile üyeleriyle paylaşılacağını ve gizlilik ilkelerini okudum.',
          ),
          subtitle: TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
            onPressed: () => context.push('/settings/privacy'),
            child: const Text('Gizlilik ilkeleri'),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox.square(dimension: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
              : const Text('Hesap oluştur'),
        ),
      ],
    );
  }
}

class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});

  final String email;

  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> {
  bool _sending = false;

  Future<void> _resend() async {
    setState(() => _sending = true);
    try {
      await ref.read(authRepositoryProvider).resendVerification(widget.email);
      if (mounted) showSnack(context, 'Doğrulama e-postası tekrar gönderildi.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'E-postanızı doğrulayın',
      subtitle:
          '${widget.email} adresine bir doğrulama bağlantısı gönderdik. '
          'Bağlantıya bu cihazdan dokunduğunuzda uygulama otomatik açılır ve oturumunuz başlar.',
      children: [
        const Icon(Icons.mark_email_unread_outlined, size: 72),
        const SizedBox(height: 24),
        OutlinedButton.icon(
          onPressed: _sending ? null : _resend,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('E-postayı tekrar gönder'),
        ),
        const SizedBox(height: 12),
        TextButton(onPressed: () => context.go('/login'), child: const Text('Giriş ekranına dön')),
      ],
    );
  }
}

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _sent = false;
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(authRepositoryProvider).sendPasswordReset(_email.text);
      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      showBack: true,
      title: 'Şifremi unuttum',
      subtitle: _sent
          ? 'Hesap mevcutsa şifre sıfırlama bağlantısı gönderildi. Bağlantıya bu cihazdan dokunun.'
          : 'E-posta adresinizi girin, size şifre sıfırlama bağlantısı gönderelim.',
      children: [
        if (!_sent) ...[
          Form(
            key: _form,
            child: TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'E-posta', prefixIcon: Icon(Icons.mail_outline_rounded)),
              validator: Validators.email,
              onFieldSubmitted: (_) => _submit(),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _submit, child: const Text('Bağlantı gönder')),
        ] else
          FilledButton(onPressed: () => context.go('/login'), child: const Text('Giriş ekranına dön')),
      ],
    );
  }
}

/// Opened from the password-recovery e-mail (recovery session is active).
class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});

  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> {
  final _form = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _password.dispose();
    _password2.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      await ref.read(authRepositoryProvider).updatePassword(_password.text);
      ref.read(passwordRecoveryProvider.notifier).clear();
      if (mounted) showSnack(context, 'Şifreniz güncellendi.');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      title: 'Yeni şifre belirleyin',
      children: [
        Form(
          key: _form,
          child: Column(
            children: [
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Yeni şifre',
                  helperText: 'En az 8 karakter, harf ve rakam',
                ),
                validator: Validators.password,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _password2,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Yeni şifre (tekrar)'),
                validator: (v) => v != _password.text ? 'Şifreler eşleşmiyor' : null,
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(onPressed: _busy ? null : _submit, child: const Text('Şifreyi kaydet')),
        TextButton(
          onPressed: () async {
            ref.read(passwordRecoveryProvider.notifier).clear();
            await ref.read(authRepositoryProvider).signOut();
          },
          child: const Text('Vazgeç ve çıkış yap'),
        ),
      ],
    );
  }
}
