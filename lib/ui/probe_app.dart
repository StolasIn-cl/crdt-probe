import 'package:flutter/material.dart';

import '../core/capability.dart';
import '../core/ids.dart';
import '../core/projection.dart';
import '../diagnostics/probe_diagnostics.dart';
import '../driver/probe_client.dart';
import '../runtime/undo_runtime.dart';
import '../runtime/yjs/yjs_runtime.dart';
import '../transport/in_memory_post_office.dart';
import '../transport/thin_server.dart';
import 'canvas_pane.dart';
import 'inspector_panel.dart';
import 'post_office_panel.dart';
import 'undo_stack_state.dart';

class ProbeApp extends StatefulWidget {
  const ProbeApp({super.key});

  @override
  State<ProbeApp> createState() => _ProbeAppState();
}

class _ProbeAppState extends State<ProbeApp> {
  YjsRuntime? _runtime;
  late ThinServer _server;
  late InMemoryPostOffice _postOffice;
  final List<ProbeClient> _clients = [];
  final Map<ClientId, DocProjection> _projections = {};
  final Map<ClientId, UndoStackState> _undoStacks = {};
  final ProbeDiagnostics _diagnostics = ProbeDiagnostics();
  final Set<ObjectId> _selected = <ObjectId>{};
  int _inspecting = 0;
  String? _bootError;
  String? _diagnosticsPath;
  String? _diagnosticsError;
  var _objectCounter = 0;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      final rt = await YjsRuntime.create();
      _server = ThinServer(onEvent: _diagnostics.record);
      _postOffice = InMemoryPostOffice(_server, onEvent: _diagnostics.record);
      for (var i = 0; i < 2; i++) {
        final c = ProbeClient(
          clientId: _server.assignClientId(),
          runtime: rt,
          postOffice: _postOffice,
          onEvent: _diagnostics.record,
        );
        // The inspector exposes undo/redo controls for every pane, so both
        // clients must opt in at open time (task 20).
        await c.open(undo: true);
        _clients.add(c);
      }
      _runtime = rt;
      await _refresh();
    } catch (e) {
      setState(() => _bootError = '$e');
    }
  }

  Future<void> _refresh() async {
    for (final c in _clients) {
      final projection = await c.read();
      _projections[c.clientId] = projection;
      _diagnostics.record('projection.snapshot', {
        'clientId': c.clientId.value,
        'projection': projection.toJson(),
      });
      final activeRuntime = _runtime;
      if (activeRuntime == null ||
          !activeRuntime.capabilities.has(Capability.readUndoStackItems)) {
        continue;
      }
      final undo = activeRuntime as UndoRuntime;
      if (activeRuntime.capabilities.has(Capability.readUndoStackItems)) {
        _undoStacks[c.clientId] = UndoStackState(
          undoLength: await undo.undoStackLength(c.clientId),
          redoLength: await undo.redoStackLength(c.clientId),
        );
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _undo(ProbeClient client) async {
    final activeRuntime = _runtime;
    if (activeRuntime == null) return;
    final undo = activeRuntime as UndoRuntime;
    await undo.undo(client.clientId);
    await client.flushOutbox();
    await _refresh();
  }

  Future<void> _redo(ProbeClient client) async {
    final activeRuntime = _runtime;
    if (activeRuntime == null) return;
    final undo = activeRuntime as UndoRuntime;
    await undo.redo(client.clientId);
    await client.flushOutbox();
    await _refresh();
  }

  Future<void> _applyTitle(ProbeClient client, ObjectId id, String next) async {
    final current = _projections[client.clientId]?.objects[id]?.text;
    if (current == null || current == next) return;

    var prefix = 0;
    while (prefix < current.length &&
        prefix < next.length &&
        current.codeUnitAt(prefix) == next.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < current.length - prefix &&
        suffix < next.length - prefix &&
        current.codeUnitAt(current.length - 1 - suffix) ==
            next.codeUnitAt(next.length - 1 - suffix)) {
      suffix++;
    }

    final undo = _runtime as UndoRuntime;
    await undo.stopCapturing(client.clientId);
    final deleteLength = current.length - prefix - suffix;
    if (deleteLength > 0) {
      await client.erase(id, prefix, deleteLength);
    }
    final inserted = next.substring(prefix, next.length - suffix);
    if (inserted.isNotEmpty) {
      await client.type(id, prefix, inserted);
    }
    await client.flushOutbox();
    await undo.stopCapturing(client.clientId);
    await _refresh();
  }

  Future<void> _applyBold(ProbeClient client, ObjectId id, int start, int end) async {
    final text = _projections[client.clientId]?.objects[id]?.text;
    if (text == null || start < 0 || start >= end || end > text.length) return;

    final undo = _runtime as UndoRuntime;
    await undo.stopCapturing(client.clientId);
    await client.format(id, start, end - start, {'bold': true});
    await client.flushOutbox();
    await undo.stopCapturing(client.clientId);
    await _refresh();
  }

  Future<void> _exportDiagnostics() async {
    final activeRuntime = _runtime;
    if (activeRuntime == null) return;
    try {
      final path = await _diagnostics.export(
        clients: _clients,
        server: _server,
        postOffice: _postOffice,
        runtime: activeRuntime,
      );
      if (mounted) {
        setState(() {
          _diagnosticsPath = path;
          _diagnosticsError = null;
        });
      }
    } catch (error) {
      if (mounted) setState(() => _diagnosticsError = '$error');
    }
  }

  void _clearDiagnostics() {
    _diagnostics.clear();
    setState(() {
      _diagnosticsPath = null;
      _diagnosticsError = null;
    });
  }

  Future<void> _addTitle(ProbeClient c) async {
    final id = ObjectId('o${_objectCounter++}');
    await c.createTitle(id, x: 20, y: 20 + 50.0 * _objectCounter, w: 160, h: 36);
    await c.type(id, 0, 'Title $id');
    await c.flushOutbox();
    await _refresh();
  }

  Future<void> _addImage(ProbeClient c) async {
    final id = ObjectId('o${_objectCounter++}');
    await c.createImage(id,
        x: 200, y: 20 + 50.0 * _objectCounter, w: 120, h: 80, src: 'placeholder');
    await c.flushOutbox();
    await _refresh();
  }

  Future<void> _move(ProbeClient c, ObjectId id, double dx, double dy) async {
    final projection = _projections[c.clientId];
    if (projection == null) return;
    final ids = _selected.contains(id) ? _selected : {id};
    final positions = <ObjectId, (double x, double y)>{};
    for (final selectedId in ids) {
      final object = projection.objects[selectedId];
      if (object == null) continue;
      positions[selectedId] = (object.x + dx, object.y + dy);
    }
    if (positions.isEmpty) return;
    await c.moveMany(positions);
    await c.flushOutbox();
    await _refresh();
  }

  void _select(ObjectId id, bool additive) {
    setState(() {
      if (additive) {
        if (!_selected.add(id)) _selected.remove(id);
      } else {
        _selected
          ..clear()
          ..add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Yjs Probe',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Yjs / Yrs Collaboration Probe'),
          actions: [
            IconButton(
              key: const Key('diagnostics-export'),
              tooltip: 'Export JSON diagnostics',
              onPressed: _runtime == null ? null : _exportDiagnostics,
              icon: const Icon(Icons.save_alt),
            ),
            IconButton(
              key: const Key('diagnostics-clear'),
              tooltip: 'Clear in-memory diagnostics',
              onPressed: _runtime == null ? null : _clearDiagnostics,
              icon: const Icon(Icons.delete_sweep),
            ),
          ],
        ),
        body: _bootError != null
            ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('boot failed:\n$_bootError')))
            : _runtime == null
                ? const Center(child: CircularProgressIndicator())
                : Column(
                    children: [
                      if (_diagnosticsPath != null || _diagnosticsError != null)
                        Padding(
                          key: const Key('diagnostics-path'),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              _diagnosticsError == null
                                  ? 'JSON exported: $_diagnosticsPath'
                                  : 'JSON export failed: $_diagnosticsError',
                              style: const TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                      Expanded(
                        child: Row(
                          children: [
                            for (final c in _clients) ...[
                              Expanded(
                                child: Column(
                                  children: [
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        TextButton(
                                            key: Key('pane-${c.clientId.value}-add-title'),
                                            onPressed: () => _addTitle(c),
                                            child: const Text('+ title')),
                                        TextButton(
                                            key: Key('pane-${c.clientId.value}-add-image'),
                                            onPressed: () => _addImage(c),
                                            child: const Text('+ image')),
                                      ],
                                    ),
                                    Expanded(
                                      child: CanvasPane(
                                        client: c,
                                        projection: _projections[c.clientId],
                                        selectedIds: _selected,
                                        onSelect: _select,
                                        onMove: (id, dx, dy) => _move(c, id, dx, dy),
                                        onRefresh: () => setState(() {}),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const VerticalDivider(width: 1),
                            ],
                            SizedBox(
                              width: 320,
                              child: InspectorPanel(
                                runtime: _runtime!,
                                client: _clients[_inspecting],
                                projection: _projections[_clients[_inspecting].clientId],
                                undoStack: _undoStacks[_clients[_inspecting].clientId],
                                onUndo: () => _undo(_clients[_inspecting]),
                                onRedo: () => _redo(_clients[_inspecting]),
                                selectedIds: _selected,
                                onApplyTitle: (id, text) =>
                                    _applyTitle(_clients[_inspecting], id, text),
                                onApplyBold: (id, start, end) =>
                                    _applyBold(_clients[_inspecting], id, start, end),
                                onSwitch: () => setState(
                                    () => _inspecting = (_inspecting + 1) % _clients.length),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      SizedBox(
                        height: 200,
                        child: PostOfficePanel(
                          postOffice: _postOffice,
                          clients: _clients,
                          diagnostics: _diagnostics,
                          onChanged: _refresh,
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
