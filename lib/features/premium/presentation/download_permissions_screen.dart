import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../family/domain/relation.dart';
import '../application/premium_providers.dart';
import '../data/premium_repository.dart';
import '../domain/premium_models.dart';

String downloadPermissionsRoute(String babyId) => '/babies/$babyId/download-permissions';

/// Parents decide, per Family Member and per product, who may download the
/// final file (plan 2.7). Parents themselves never need a grant.
class DownloadPermissionsScreen extends ConsumerWidget {
  const DownloadPermissionsScreen({super.key, required this.babyId});

  final String babyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = ref.watch(downloadPermissionsProvider(babyId));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('İndirme izinleri')),
      body: AsyncValueView<List<DownloadPermission>>(
        value: rows,
        onRetry: () => ref.invalidate(downloadPermissionsProvider(babyId)),
        data: (list) {
          final members = <String, List<DownloadPermission>>{};
          for (final r in list) {
            (members[r.memberUserId] ??= []).add(r);
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
                child: Text(
                  'Anne ve Baba satın alınan dosyaları her zaman indirebilir. Aile üyeleri yalnızca sizin paylaştığınız '
                  'ürünü, aile paketi etkinken indirebilir. İzni kaldırdığınızda yeni indirme bağlantısı alınamaz.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              if (members.isEmpty)
                const EmptyState(
                  icon: Icons.group_outlined,
                  title: 'Aile üyesi yok',
                  message: 'Bu bebeğe katılan aile üyeleri burada listelenir.',
                ),
              for (final entry in members.entries) _MemberCard(babyId: babyId, rows: entry.value),
            ],
          );
        },
      ),
    );
  }
}

class _MemberCard extends ConsumerWidget {
  const _MemberCard({required this.babyId, required this.rows});

  final String babyId;
  final List<DownloadPermission> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final first = rows.first;
    final relation = relationText(Relation.fromKey(first.relation), first.relationLabel);
    final name = first.displayName.trim().isEmpty ? relation : '${first.displayName.trim()} · $relation';
    final ordered = [...rows]..sort((a, b) => a.product.index.compareTo(b.product.index));
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(name, style: Theme.of(context).textTheme.titleMedium),
          ),
          for (final r in ordered)
            SwitchListTile(
              title: Text(r.product.title),
              subtitle: r.productOwned ? null : const Text('Satın alınmadı'),
              value: r.granted,
              onChanged: r.productOwned || r.granted
                  ? (v) async {
                      await runWithProgress(
                        context,
                        () => ref
                            .read(premiumRepositoryProvider)
                            .setDownloadPermission(
                              babyId: babyId,
                              memberUserId: r.memberUserId,
                              product: r.product,
                              allowed: v,
                            ),
                        success: v ? 'Paylaşıldı' : 'İzin kaldırıldı',
                      );
                      ref.invalidate(downloadPermissionsProvider(babyId));
                    }
                  : null,
            ),
        ],
      ),
    );
  }
}
