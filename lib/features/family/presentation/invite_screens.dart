import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/utils/validators.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../babies/application/baby_providers.dart';
import '../application/family_providers.dart';
import '../data/family_repository.dart';
import '../domain/invitation.dart';
import '../domain/permission.dart';
import '../domain/relation.dart';
import 'family_screen.dart';
import 'permission_editor.dart';

class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key});

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen> {
  final _form = GlobalKey<FormState>();
  final _label = TextEditingController();
  final _email = TextEditingController();
  Relation _relation = Relation.teyze;
  late Set<AppPermission> _permissions = Relation.teyze.defaultPermissions;
  bool _admin = false;
  int _days = 7;
  bool _busy = false;
  Invitation? _created;

  @override
  void dispose() {
    _label.dispose();
    _email.dispose();
    super.dispose();
  }

  Future<void> _create(String babyId) async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final inv = await ref
          .read(familyRepositoryProvider)
          .createInvitation(
            babyId: babyId,
            relation: _relation,
            relationLabel: _relation == Relation.diger ? _label.text : null,
            isAdmin: _admin,
            permissions: _permissions,
            email: _email.text,
            validFor: Duration(days: _days),
          );
      ref.invalidate(invitationsProvider(babyId));
      setState(() => _created = inv);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final access = ref.watch(accessProvider(baby.id));
    // Only Anne / Baba invite a parent, and a parent invitation is always an
    // equal admin; nobody else can be an admin (decisions P-5 / P-8).
    final actorIsParent = ref.watch(myMembershipProvider(baby.id))?.isParentAdmin ?? false;
    final theme = Theme.of(context);
    final created = _created;

    if (created != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Davet hazır')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Icon(Icons.mark_email_read_outlined, size: 64),
            const SizedBox(height: 16),
            Text(
              'Bu kodu ${relationText(created.relation, created.relationLabel).toLowerCase()} ile paylaşın',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 20),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SelectableText(
                  InviteCode.pretty(created.code),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineMedium?.copyWith(
                    letterSpacing: 4,
                    fontFamily: 'Nunito',
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Tek kullanımlıktır ve $_days gün geçerlidir.${created.invitedEmail == null ? '' : ' Yalnızca ${created.invitedEmail} ile kullanılabilir.'}',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () => SharePlus.instance.share(ShareParams(text: invitationMessage(created))),
              icon: const Icon(Icons.share_rounded),
              label: const Text('Davet bağlantısını paylaş'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: created.code));
                if (context.mounted) showSnack(context, 'Kod kopyalandı');
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('Kodu kopyala'),
            ),
            const SizedBox(height: 10),
            TextButton(onPressed: () => context.pop(), child: const Text('Tamam')),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text('${baby.firstName} için davet')),
      body: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
          children: [
            Text('Yakınlık', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final r in Relation.values)
                  if (!r.isParent || actorIsParent)
                    ChoiceChip(
                      label: Text(r.label),
                      selected: _relation == r,
                      onSelected: (_) => setState(() {
                        _relation = r;
                        _permissions = r.defaultPermissions.where((p) => access.isAdmin || !p.isManagement).toSet();
                        _admin = actorIsParent && r.defaultAdmin;
                      }),
                    ),
              ],
            ),
            if (_relation == Relation.diger) ...[
              const SizedBox(height: 12),
              TextFormField(
                controller: _label,
                decoration: const InputDecoration(labelText: 'Yakınlık adı', hintText: 'Kuzen, Yenge, Vaftiz annesi…'),
                validator: (v) => Validators.required(v, field: 'Yakınlık') ?? Validators.maxLength(v, 40),
              ),
            ],
            const SizedBox(height: 16),
            TextFormField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(
                labelText: 'E-posta (isteğe bağlı)',
                helperText: 'Girilirse davet yalnızca bu e-posta ile kabul edilebilir.',
              ),
              validator: Validators.optionalEmail,
            ),
            const SizedBox(height: 16),
            Text('Geçerlilik', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: const [
                ButtonSegment(value: 1, label: Text('1 gün')),
                ButtonSegment(value: 7, label: Text('7 gün')),
                ButtonSegment(value: 30, label: Text('30 gün')),
              ],
              selected: {_days},
              onSelectionChanged: (s) => setState(() => _days = s.first),
            ),
            const SizedBox(height: 16),
            if (_admin)
              Text(
                '${_relation.label} daveti, sizinle eşit yönetici yetkisiyle gönderilir.',
                style: theme.textTheme.bodyMedium,
              ),
            if (!_admin) ...[
              const SizedBox(height: 8),
              Text('Yetkiler', style: theme.textTheme.titleSmall),
              PermissionEditor(
                value: _permissions,
                canGrantManagement: access.isAdmin,
                onChanged: (v) => setState(() => _permissions = v),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(onPressed: _busy ? null : () => _create(baby.id), child: const Text('Davet kodu oluştur')),
          ],
        ),
      ),
    );
  }
}

/// Multi-child families: add a member of a sibling's family directly.
class AddFromSiblingScreen extends ConsumerStatefulWidget {
  const AddFromSiblingScreen({super.key});

  @override
  ConsumerState<AddFromSiblingScreen> createState() => _AddFromSiblingScreenState();
}

class _AddFromSiblingScreenState extends ConsumerState<AddFromSiblingScreen> {
  final Map<String, Relation> _selected = {};

  @override
  Widget build(BuildContext context) {
    final baby = ref.watch(activeBabyProvider);
    if (baby == null) return const Scaffold(body: LoadingView());
    final babies = (ref.watch(babiesProvider).value ?? const []).where((b) => b.id != baby.id).toList();
    final current = {for (final m in ref.watch(membersProvider(baby.id)).value ?? const []) m.userId};
    // Only Anne / Baba add a parent (decision P-8).
    final actorIsParent = ref.watch(myMembershipProvider(baby.id))?.isParentAdmin ?? false;
    final candidates = <String, (String name, String? avatar, String from)>{};
    for (final b in babies) {
      if (!ref.watch(accessProvider(b.id)).isAdmin) continue;
      for (final m in ref.watch(membersProvider(b.id)).value ?? const []) {
        if (!current.contains(m.userId)) {
          candidates[m.userId] = (m.shownName, m.avatarPath, '${b.firstName}: ${m.relationName}');
        }
      }
    }
    return Scaffold(
      appBar: AppBar(title: Text('${baby.firstName} ailesine ekle')),
      body: candidates.isEmpty
          ? const EmptyState(
              icon: Icons.diversity_1_rounded,
              title: 'Eklenecek kimse yok',
              message: 'Diğer çocuklarınızın ailesindeki herkes zaten burada.',
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
              children: [
                const Text(
                  'Yakınlık her çocuk için ayrı tutulur (Defne, Ege\'nin ablasıdır). Seçtiğiniz kişiler varsayılan yetkilerle eklenir; sonra değiştirebilirsiniz.',
                ),
                const SizedBox(height: 12),
                for (final e in candidates.entries)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CheckboxListTile(
                            value: _selected.containsKey(e.key),
                            onChanged: (v) =>
                                setState(() => v == true ? _selected[e.key] = Relation.diger : _selected.remove(e.key)),
                            title: Text(e.value.$1, style: const TextStyle(fontWeight: FontWeight.w800)),
                            subtitle: Text(e.value.$3),
                          ),
                          if (_selected.containsKey(e.key))
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: DropdownButtonFormField<Relation>(
                                initialValue: _selected[e.key],
                                decoration: InputDecoration(labelText: '${baby.firstName} için yakınlık'),
                                items: [
                                  for (final r in Relation.values)
                                    if (!r.isParent || actorIsParent) DropdownMenuItem(value: r, child: Text(r.label)),
                                ],
                                onChanged: (r) => setState(() => _selected[e.key] = r ?? Relation.diger),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
      bottomNavigationBar: _selected.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: () async {
                    final done = await runWithProgress(context, () async {
                      for (final e in _selected.entries) {
                        await ref
                            .read(familyRepositoryProvider)
                            .addFromSibling(
                              babyId: baby.id,
                              userId: e.key,
                              relation: e.value,
                              permissions: e.value.defaultPermissions.where((p) => !p.isManagement).toSet(),
                              isAdmin: e.value.defaultAdmin,
                            );
                      }
                      return true;
                    }, success: 'Aile üyeleri eklendi');
                    if (done == true && context.mounted) {
                      ref.invalidate(membersProvider(baby.id));
                      context.pop();
                    }
                  },
                  child: Text('${_selected.length} kişiyi ekle'),
                ),
              ),
            ),
    );
  }
}
