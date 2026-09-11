import 'package:flutter/material.dart';

import '../core/capability.dart';
import '../core/ids.dart';
import '../core/projection.dart';
import '../driver/probe_client.dart';
import '../runtime/crdt_runtime.dart';
import 'undo_stack_state.dart';

class InspectorPanel extends StatelessWidget {
  const InspectorPanel({
    super.key,
    required this.runtime,
    required this.client,
    required this.projection,
    required this.onSwitch,
    required this.undoStack,
    required this.onUndo,
    required this.onRedo,
    required this.selectedIds,
    required this.onApplyTitle,
    required this.onApplyBold,
  });

  final CrdtRuntime runtime;
  final ProbeClient client;
  final DocProjection? projection;
  final VoidCallback onSwitch;
  final UndoStackState? undoStack;
  final Future<void> Function()? onUndo;
  final Future<void> Function()? onRedo;
  final Set<ObjectId> selectedIds;
  final Future<void> Function(ObjectId id, String text)? onApplyTitle;
  final Future<void> Function(ObjectId id, int start, int end)? onApplyBold;

  @override
  Widget build(BuildContext context) {
    final p = projection;
    return ListView(
      key: const Key('inspector-list'),
      padding: const EdgeInsets.all(8),
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Inspector — ${client.clientId.label}',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            IconButton(
              key: const Key('inspector-switch'),
              onPressed: onSwitch,
              icon: const Icon(Icons.swap_horiz),
            ),
          ],
        ),
        _row(context, 'clientID', '${client.clientId.value}', null),
        _row(context, 'lastSeq', '${client.lastSeq}', null),
        _row(context, 'state vector', p?.stateVectorB64 ?? '-', Capability.readStateVector,
            key: const Key('inspector-row-state-vector')),
        _row(
          context,
          'format markers',
          p == null
              ? '-'
              : p.objects.entries
                  .where((e) => e.value.delta != null)
                  .map((e) => '${e.key.value}: ${e.value.delta}')
                  .join('\n'),
          Capability.enumerateFormatMarkers,
          key: const Key('inspector-row-format-markers'),
        ),
        _row(context, 'tombstones', '', Capability.enumerateTombstones,
            key: const Key('inspector-row-tombstones')),
        _row(
          context,
          'undo stack items',
          undoStack == null ? '' : 'undo ${undoStack!.undoLength} / redo ${undoStack!.redoLength}',
          Capability.readUndoStackItems,
          key: const Key('inspector-row-undo-stack-items'),
        ),
        if (runtime.capabilities.has(Capability.readUndoStackItems))
          Row(
            children: [
              Expanded(
                child: TextButton(
                  key: const Key('inspector-undo'),
                  onPressed: undoStack?.undoLength == null || undoStack!.undoLength == 0
                      ? null
                      : () async => onUndo?.call(),
                  child: const Text('Undo'),
                ),
              ),
              Expanded(
                child: TextButton(
                  key: const Key('inspector-redo'),
                  onPressed: undoStack?.redoLength == null || undoStack!.redoLength == 0
                      ? null
                      : () async => onRedo?.call(),
                  child: const Text('Redo'),
                ),
              ),
            ],
          ),
        if (selectedIds.isNotEmpty)
          _SelectionSummary(selectedIds: selectedIds),
        if (selectedIds.isNotEmpty && onApplyTitle != null)
          Builder(
            builder: (context) {
              final selectedObjectId = selectedIds.first;
              final selected = p?.objects[selectedObjectId];
              if (selected?.kind != 'title' || selected?.text == null) {
                return const SizedBox.shrink();
              }
              return _TitleEditor(
                key: const Key('inspector-title-editor-section'),
                value: selected!.text!,
                onApply: (text) => onApplyTitle!(selectedObjectId!, text),
              );
            },
          ),
        if (selectedIds.isNotEmpty && onApplyBold != null)
          Builder(
            builder: (context) {
              final selectedObjectId = selectedIds.first;
              final selected = p?.objects[selectedObjectId];
              if (selected?.kind != 'title' || selected?.text == null) {
                return const SizedBox.shrink();
              }
              return _FormatEditor(
                key: const Key('inspector-format-editor-section'),
                textLength: selected!.text!.length,
                onApply: (start, end) =>
                    onApplyBold!(selectedObjectId!, start, end),
              );
            },
          ),
        _row(context, 'per-character identity', '', Capability.enumeratePerCharacterIdentity,
            key: const Key('inspector-row-per-character-identity')),
        const Divider(),
        Text('objects', style: Theme.of(context).textTheme.labelLarge),
        if (p != null)
          for (final e in p.objects.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                key: Key('inspector-object-${e.key.value}'),
                '${e.key.value} ${e.value.kind} '
                '(${e.value.x.toStringAsFixed(0)},${e.value.y.toStringAsFixed(0)}) '
                '${e.value.kind == 'title' ? '"${e.value.text}"' : e.value.src}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              ),
            ),
      ],
    );
  }

  /// A row whose capability the runtime lacks renders as an explicit greyed
  /// note, never as blank. Blank reads as "there is nothing there"; the note
  /// reads as "this cannot be seen" (ticket 17 §9).
  Widget _row(BuildContext context, String label, String value, Capability? needs, {Key? key}) {
    final unavailable = needs != null && !runtime.capabilities.has(needs);
    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          if (unavailable)
            Text(
              'unobservable on ${runtime.name}',
              style: TextStyle(
                color: Theme.of(context).disabledColor,
                fontStyle: FontStyle.italic,
                fontSize: 11,
              ),
            )
          else
            Text(value, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
        ],
      ),
    );
  }
}

class _SelectionSummary extends StatelessWidget {
  const _SelectionSummary({required this.selectedIds});

  final Set<ObjectId> selectedIds;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            const Text('selection'),
            for (final id in selectedIds)
              Chip(
                key: Key('inspector-selected-${id.value}'),
                label: Text(id.value),
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      );
}

class _TitleEditor extends StatefulWidget {
  const _TitleEditor({
    super.key,
    required this.value,
    required this.onApply,
  });

  final String value;
  final ValueChanged<String> onApply;

  @override
  State<_TitleEditor> createState() => _TitleEditorState();
}

class _TitleEditorState extends State<_TitleEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(covariant _TitleEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_focusNode.hasFocus && _controller.text != widget.value) {
      _controller.value = TextEditingValue(text: widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text('selected title', style: Theme.of(context).textTheme.labelLarge),
          TextField(
            key: const Key('inspector-title-editor'),
            controller: _controller,
            focusNode: _focusNode,
            decoration: const InputDecoration(labelText: 'text'),
          ),
          TextButton(
            key: const Key('inspector-title-apply'),
            onPressed: () => widget.onApply(_controller.text),
            child: const Text('Apply title'),
          ),
        ],
      );
}

class _FormatEditor extends StatefulWidget {
  const _FormatEditor({
    super.key,
    required this.textLength,
    required this.onApply,
  });

  final int textLength;
  final Future<void> Function(int start, int end) onApply;

  @override
  State<_FormatEditor> createState() => _FormatEditorState();
}

class _FormatEditorState extends State<_FormatEditor> {
  late final TextEditingController _startController;
  late final TextEditingController _endController;

  @override
  void initState() {
    super.initState();
    _startController = TextEditingController(text: '0');
    _endController = TextEditingController(text: '${widget.textLength}');
  }

  @override
  void didUpdateWidget(covariant _FormatEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    final end = int.tryParse(_endController.text);
    if (end != null && end > widget.textLength) {
      _endController.text = '${widget.textLength}';
    }
  }

  @override
  void dispose() {
    _startController.dispose();
    _endController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 4),
          Text('bold range [start, end)',
              style: Theme.of(context).textTheme.labelLarge),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('inspector-format-start'),
                  controller: _startController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'start'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  key: const Key('inspector-format-end'),
                  controller: _endController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'end'),
                ),
              ),
            ],
          ),
          TextButton(
            key: const Key('inspector-format-bold'),
            onPressed: () {
              final start = int.tryParse(_startController.text);
              final end = int.tryParse(_endController.text);
              if (start == null || end == null) return;
              widget.onApply(start, end);
            },
            child: const Text('Apply bold'),
          ),
        ],
      );
}
