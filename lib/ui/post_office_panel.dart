import 'dart:convert';

import 'package:flutter/material.dart';

import '../diagnostics/probe_diagnostics.dart';
import '../driver/probe_client.dart';
import '../transport/in_memory_post_office.dart';

/// The operator's control over delivery order. The arrival-order-reversal
/// experiment is performed here, by hand and visibly, rather than being buried
/// in a test nobody can be shown.
class PostOfficePanel extends StatelessWidget {
  const PostOfficePanel({
    super.key,
    required this.postOffice,
    required this.clients,
    required this.diagnostics,
    required this.onChanged,
  });

  final InMemoryPostOffice postOffice;
  final List<ProbeClient> clients;
  final ProbeDiagnostics diagnostics;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final c in clients) ...[
          Expanded(child: _queue(context, c)),
          const VerticalDivider(width: 1),
        ],
        SizedBox(width: 380, child: _diagnostics(context)),
      ],
    );
  }

  Widget _diagnostics(BuildContext context) {
    final events = diagnostics.events;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text('diagnostics (${events.length})',
              style: Theme.of(context).textTheme.labelLarge),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            children: [
              for (final event in events.reversed.take(50))
                Text(
                  '#${event['eventNo']} ${event['kind']}\n'
                  '${jsonEncode(event['data'])}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _queue(BuildContext context, ProbeClient c) {
    final pending = postOffice.pendingFor(c.clientId);
    final n = c.clientId.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text('inbox of ${c.clientId.label}  (${pending.length})',
              style: Theme.of(context).textTheme.labelLarge),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              key: Key('inbox-$n-release'),
              onPressed: pending.isEmpty
                  ? null
                  : () async {
                      await c.receiveAll();
                      await onChanged();
                    },
              child: const Text('Release'),
            ),
            TextButton(
              key: Key('inbox-$n-release-reversed'),
              onPressed: pending.length < 2
                  ? null
                  : () async {
                      await c.receiveReversed();
                      await onChanged();
                    },
              child: const Text('Release reversed'),
            ),
            TextButton(
              key: Key('inbox-$n-step'),
              onPressed: pending.isEmpty
                  ? null
                  : () async {
                      final e = postOffice.step(c.clientId);
                      if (e != null) {
                        await c.runtime.applyUpdate(c.clientId, e.payload, seq: e.seq);
                        if (e.seq > c.lastSeq) c.lastSeq = e.seq;
                      }
                      await onChanged();
                    },
              child: const Text('Step'),
            ),
            TextButton(
              key: Key('inbox-$n-drop'),
              onPressed: pending.isEmpty
                  ? null
                  : () async {
                      postOffice.drop(c.clientId);
                      await onChanged();
                    },
              child: const Text('Drop'),
            ),
            TextButton(
              key: Key('inbox-$n-resync'),
              onPressed: () async {
                await c.resyncFromServer();
                await onChanged();
              },
              child: const Text('Resync'),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            children: [
              for (final e in pending)
                ListTile(
                  dense: true,
                  title: Text('seq ${e.seq} from ${e.authorId.label}'),
                  subtitle: Text('${e.payload.length} bytes, baseSeq ${e.baseSeq}'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
