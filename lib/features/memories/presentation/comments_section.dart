import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/content/content_revision.dart';
import '../../../core/utils/dates.dart';
import '../../../core/widgets/avatar.dart';
import '../../../core/widgets/feedback.dart';
import '../../../core/widgets/states.dart';
import '../../family/application/family_providers.dart';
import '../../family/domain/permission.dart';
import '../application/memory_providers.dart';
import '../data/memory_repository.dart';
import '../domain/comment.dart';

/// Comments on memories / "aile notları" on milestones.
class CommentsSection extends ConsumerStatefulWidget {
  const CommentsSection({super.key, required this.babyId, required this.kind, required this.targetId, this.title = 'Yorumlar'});

  final String babyId;
  final TargetKind kind;
  final String targetId;
  final String title;

  @override
  ConsumerState<CommentsSection> createState() => _CommentsSectionState();
}

class _CommentsSectionState extends ConsumerState<CommentsSection> {
  final _ctrl = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    setState(() => _sending = true);
    try {
      await ref.read(memoryRepositoryProvider).addComment(
        babyId: widget.babyId,
        kind: widget.kind,
        targetId: widget.targetId,
        body: text,
      );
      _ctrl.clear();
      ref.read(contentRevisionProvider.notifier).bump();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final comments = ref.watch(commentsProvider((widget.kind, widget.targetId)));
    final access = ref.watch(accessProvider(widget.babyId));
    final members = ref.watch(membersProvider(widget.babyId)).value ?? const [];
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.title, style: theme.textTheme.titleMedium),
        const SizedBox(height: 10),
        AsyncValueView<List<Comment>>(
          value: comments,
          onRetry: () => ref.invalidate(commentsProvider((widget.kind, widget.targetId))),
          data: (list) => Column(
            children: [
              if (list.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('İlk notu siz bırakın.', style: theme.textTheme.bodySmall),
                ),
              for (final c in list)
                Builder(builder: (context) {
                  final author = members.where((m) => m.userId == c.authorId).firstOrNull;
                  final canDelete = c.authorId == access.userId || access.can(AppPermission.manageContent);
                  return ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: AppAvatar(name: author?.shownName ?? '?', path: author?.avatarPath, radius: 18),
                    title: Text(author?.introduction ?? 'Eski bir aile üyesi', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5)),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.body, style: theme.textTheme.bodyMedium),
                        Text(Dates.short(c.createdAt.toLocal()), style: theme.textTheme.labelSmall),
                      ],
                    ),
                    trailing: canDelete
                        ? IconButton(
                            tooltip: 'Sil',
                            icon: const Icon(Icons.delete_outline_rounded, size: 20),
                            onPressed: () async {
                              await runWithProgress(context, () => ref.read(memoryRepositoryProvider).deleteComment(c.id));
                              ref.read(contentRevisionProvider.notifier).bump();
                            },
                          )
                        : null,
                  );
                }),
            ],
          ),
        ),
        if (access.can(AppPermission.comment))
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 2000,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(hintText: 'Bir not bırakın…', counterText: ''),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Gönder',
                onPressed: _sending ? null : _send,
                icon: const Icon(Icons.send_rounded),
              ),
            ],
          ),
      ],
    );
  }
}
