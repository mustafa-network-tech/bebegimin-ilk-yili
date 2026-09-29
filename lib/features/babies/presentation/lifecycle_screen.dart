import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../app/theme.dart';
import '../../../core/content/lifecycle_revision.dart';
import '../../../core/errors/app_exception.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../family/application/family_providers.dart';
import '../application/baby_lifecycle_providers.dart';
import '../application/baby_providers.dart';
import '../data/baby_lifecycle_repository.dart';
import '../domain/baby_lifecycle.dart';
import 'lifecycle_widgets.dart';

/// Server lifecycle of one baby and the one-time extension request.
class BabyLifecycleScreen extends ConsumerWidget {
  const BabyLifecycleScreen({super.key, required this.babyId});

  final String babyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final baby = ref.watch(babyByIdProvider(babyId));
    final lifecycle = ref.watch(babyLifecycleProvider(babyId));
    return Scaffold(
      appBar: AppBar(title: Text(baby == null ? 'İlk yıl arşivi' : '${baby.firstName} · İlk yıl arşivi')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.read(lifecycleRevisionProvider.notifier).bump();
          await ref.read(babyLifecycleProvider(babyId).future);
        },
        child: AsyncValueView(
          value: lifecycle,
          onRetry: () => ref.read(lifecycleRevisionProvider.notifier).bump(),
          data: (l) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _StatusCard(lifecycle: l),
              const SizedBox(height: 12),
              _DatesCard(lifecycle: l),
              const SizedBox(height: 12),
              _ExtensionCard(babyId: babyId, lifecycle: l),
              if (l.isLocked) ...[const SizedBox(height: 12), const _LockedInfoCard()],
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.lifecycle});

  final BabyLifecycle lifecycle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = lifecycle;
    return Card(
      color: AppColors.apricot.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(l.isLocked ? Icons.lock_rounded : Icons.hourglass_bottom_rounded, size: 40, color: AppColors.apricot),
            const SizedBox(height: 10),
            Text(
              l.isLocked ? 'İlk Yılı tamamlandı' : (l.remainingDays == 1 ? 'Son gün' : '${l.remainingDays} gün kaldı'),
              style: theme.textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              l.isLocked
                  ? 'Arşiv kilitli ve salt okunur.'
                  : 'Bu süre boyunca anı, fotoğraf, video, ilk, mektup ve zaman kapsülü ekleyebilirsiniz.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _DatesCard extends StatelessWidget {
  const _DatesCard({required this.lifecycle});

  final BabyLifecycle lifecycle;

  @override
  Widget build(BuildContext context) {
    final l = lifecycle;
    return Card(
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.event_rounded),
            title: const Text('Standart kapanış'),
            subtitle: Text(Dates.longWithWeekday(l.baseCloseDate)),
          ),
          if (l.hasApprovedExtension)
            ListTile(
              leading: const Icon(Icons.more_time_rounded),
              title: Text('Onaylı uzatma: ${l.approvedExtensionDays} gün'),
              subtitle: Text('Yeni kapanış: ${Dates.longWithWeekday(l.effectiveCloseDate)}'),
            ),
          const ListTile(
            leading: Icon(Icons.info_outline_rounded),
            title: Text('Kapanış saati'),
            subtitle: Text('Kapanış günü İstanbul saatiyle 00:00\'da başlar; arşiv o anda kilitlenir.'),
          ),
        ],
      ),
    );
  }
}

class _LockedInfoCard extends StatelessWidget {
  const _LockedInfoCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Column(
        children: [
          ListTile(
            leading: Icon(Icons.visibility_rounded),
            title: Text('Açık kalanlar'),
            subtitle: Text('Anılar, albüm, takvim, arama, favoriler ve aile üyeliği yönetimi.'),
          ),
          ListTile(
            leading: Icon(Icons.block_rounded),
            title: Text('Kapananlar'),
            subtitle: Text('Yeni içerik ekleme, düzenleme, silme ve bebek profilini değiştirme.'),
          ),
        ],
      ),
    );
  }
}

class _ExtensionCard extends ConsumerStatefulWidget {
  const _ExtensionCard({required this.babyId, required this.lifecycle});

  final String babyId;
  final BabyLifecycle lifecycle;

  @override
  ConsumerState<_ExtensionCard> createState() => _ExtensionCardState();
}

class _ExtensionCardState extends ConsumerState<_ExtensionCard> {
  static const maxDays = 30;
  int _days = 7;
  bool _busy = false;

  Future<void> _submit() async {
    final ok = await confirm(
      context,
      title: '$_days günlük uzatma istensin mi?',
      message:
          'Her bebek için yalnızca bir kez uzatma istenebilir. Talep Super Admin tarafından değerlendirilir ve '
          'karar değiştirilemez. Standart kapanışa kadar sonuçlanmazsa talebin süresi dolar.',
      confirmLabel: 'Talep gönder',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(babyLifecycleRepositoryProvider).requestExtension(babyId: widget.babyId, days: _days);
      if (mounted) showSnack(context, 'Uzatma talebiniz gönderildi.');
    } catch (e) {
      if (mounted) showSnack(context, _extensionError(e), error: true);
    } finally {
      // Success and refusals alike: show the server's current state.
      ref.read(lifecycleRevisionProvider.notifier).bump();
      if (mounted) setState(() => _busy = false);
    }
  }

  static String _extensionError(Object e) {
    if (e is PostgrestException) {
      if (e.message.contains('already requested')) return 'Bu bebek için daha önce uzatma talebi oluşturulmuş.';
      if (e.message.contains('before base close')) {
        return 'Standart kapanış tarihi geldiği için uzatma talep edilemez.';
      }
    }
    return AppException.from(e).message;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = widget.lifecycle;
    final membership = ref.watch(myMembershipProvider(widget.babyId));
    final isParent = membership != null && membership.isAdmin && membership.relation.isParent;
    final status = extensionStatusText(l);

    final List<Widget> content;
    if (status != null) {
      content = [
        Text(status, style: theme.textTheme.bodyLarge),
        if (l.extensionStatus == BabyExtensionStatus.pending) ...[
          const SizedBox(height: 6),
          Text(
            'Standart kapanış tarihine (${Dates.long(l.baseCloseDate)}) kadar sonuçlanmazsa talebin süresi dolar '
            've arşiv kilitlenir.',
            style: theme.textTheme.bodySmall,
          ),
        ],
        if (l.extensionStatus != BabyExtensionStatus.pending) ...[
          const SizedBox(height: 6),
          Text('Uzatma hakkı kullanıldı; yeni talep oluşturulamaz.', style: theme.textTheme.bodySmall),
        ],
      ];
    } else if (!l.canRequestExtension) {
      content = [
        Text(
          'Uzatma talebi yalnızca standart kapanış tarihinden önce oluşturulabilir.',
          style: theme.textTheme.bodyMedium,
        ),
      ];
    } else if (!isParent) {
      content = [Text('Uzatma talebini Anne veya Baba oluşturabilir.', style: theme.textTheme.bodyMedium)];
    } else {
      content = [
        Text(
          'Arşive içerik eklemek için ek süreye ihtiyacınız varsa bir kez, 1–30 gün arası uzatma isteyebilirsiniz.',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 12),
        Text('İstenen süre: $_days gün', style: theme.textTheme.titleSmall),
        Slider(
          value: _days.toDouble(),
          min: 1,
          max: maxDays.toDouble(),
          divisions: maxDays - 1,
          label: '$_days gün',
          semanticFormatterCallback: (v) => '${v.round()} gün',
          onChanged: _busy ? null : (v) => setState(() => _days = v.round()),
        ),
        Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(child: Text('Bu hak yalnızca bir kez kullanılabilir.', style: theme.textTheme.bodySmall)),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: _busy
              ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.more_time_rounded),
          label: const Text('Uzatma talep et'),
        ),
      ];
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Süre uzatma', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...content,
          ],
        ),
      ),
    );
  }
}
