import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/ids.dart';
import '../core/projection.dart';
import '../driver/probe_client.dart';

class CanvasPane extends StatelessWidget {
  const CanvasPane({
    super.key,
    required this.client,
    required this.projection,
    required this.selectedIds,
    required this.onSelect,
    required this.onMove,
    required this.onRefresh,
  });

  final ProbeClient client;
  final DocProjection? projection;
  final Set<ObjectId> selectedIds;
  final void Function(ObjectId id, bool additive) onSelect;
  final void Function(ObjectId id, double dx, double dy) onMove;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final p = projection;
    return Column(
      children: [
        _header(context),
        const Divider(height: 1),
        Expanded(
          child: Container(
            color: Theme.of(context).colorScheme.surfaceContainerLowest,
            child: p == null
                ? const Center(child: Text('not opened'))
                : Stack(
                    children: [
                      for (final e in p.objects.entries)
                        _objectBox(context, e.key, e.value),
                    ],
                  ),
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context) {
    final held = client.postOffice.isHeld(client.clientId);
    final pending = client.postOffice.pendingFor(client.clientId).length;
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          Text(client.clientId.label, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(width: 12),
          Text('lastSeq ${client.lastSeq}'),
          const SizedBox(width: 12),
          Text('pending $pending'),
          const Spacer(),
          FilterChip(
            key: Key('pane-${client.clientId.value}-online-toggle'),
            label: Text(held ? 'offline' : 'online'),
            selected: held,
            onSelected: (v) {
              v ? client.postOffice.hold(client.clientId) : client.postOffice.unhold(client.clientId);
              onRefresh();
            },
          ),
        ],
      ),
    );
  }

  Widget _objectBox(BuildContext context, ObjectId id, ObjectProjection o) {
    final selected = selectedIds.contains(id);
    return Positioned(
      key: Key('pane-${client.clientId.value}-object-${id.value}'),
      left: o.x,
      top: o.y,
      width: o.w,
      height: o.h,
      child: GestureDetector(
        onTap: () => onSelect(id, _isAdditiveSelection()),
        onPanUpdate: (d) => onMove(id, d.delta.dx, d.delta.dy),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.outlineVariant,
              width: selected ? 2 : 1,
            ),
            color: o.kind == 'image'
                ? Theme.of(context).colorScheme.secondaryContainer
                : null,
          ),
          alignment: Alignment.center,
          child: o.kind == 'title' ? _titleText(context, id, o) : const Text('image'),
        ),
      ),
    );
  }

  bool _isAdditiveSelection() {
    final keys = HardwareKeyboard.instance.logicalKeysPressed;
    return keys.contains(LogicalKeyboardKey.controlLeft) ||
        keys.contains(LogicalKeyboardKey.controlRight) ||
        keys.contains(LogicalKeyboardKey.metaLeft) ||
        keys.contains(LogicalKeyboardKey.metaRight);
  }

  Widget _titleText(BuildContext context, ObjectId id, ObjectProjection object) {
    final chunks = object.delta ?? [
      {'insert': object.text ?? ''},
    ];
    final spans = <InlineSpan>[];
    for (final chunk in chunks) {
      final insert = chunk['insert'];
      if (insert is! String) continue;
      final attributes = chunk['attributes'];
      final bold = attributes is Map && attributes['bold'] == true;
      spans.add(
        TextSpan(
          text: insert,
          style: TextStyle(fontWeight: bold ? FontWeight.bold : null),
        ),
      );
    }
    return RichText(
      key: Key('pane-${client.clientId.value}-title-text-${id.value}'),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: DefaultTextStyle.of(context).style,
        children: spans,
      ),
    );
  }
}
