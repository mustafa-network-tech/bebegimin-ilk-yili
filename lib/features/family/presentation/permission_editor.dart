import 'package:flutter/material.dart';

import '../domain/permission.dart';

/// Switch list for granular permissions. Management permissions can only be
/// granted by admins (enforced again by the database).
class PermissionEditor extends StatelessWidget {
  const PermissionEditor({
    super.key,
    required this.value,
    required this.onChanged,
    required this.canGrantManagement,
    this.enabled = true,
  });

  final Set<AppPermission> value;
  final ValueChanged<Set<AppPermission>> onChanged;
  final bool canGrantManagement;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final p in AppPermission.values)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(p.label),
            subtitle: p.isManagement && !canGrantManagement ? const Text('Yalnızca yöneticiler verebilir') : null,
            value: value.contains(p),
            onChanged: !enabled || (p.isManagement && !canGrantManagement)
                ? null
                : (v) {
                    final next = {...value};
                    v ? next.add(p) : next.remove(p);
                    // Viewing is required for anything else to make sense.
                    if (v && p != AppPermission.viewMemories && p != AppPermission.viewAlbum) {
                      next.add(AppPermission.viewMemories);
                    }
                    onChanged(next);
                  },
          ),
      ],
    );
  }
}
