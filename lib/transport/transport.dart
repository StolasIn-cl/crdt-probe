import 'dart:typed_data';

import '../core/envelope.dart';
import '../core/ids.dart';

/// Seam 2. A real socket cannot be asked to choose an arrival order and does
/// not repeat itself, so it cannot carry the arrival-order-reversal experiment.
/// The in-memory implementation is the source of determinism, and a
/// `WebSocketTransport` is left for a later phase.
abstract interface class Transport {
  void register(ClientId c);
  void send(ClientId author, Uint8List payload, int baseSeq);
  List<UpdateEnvelope> pendingFor(ClientId c);
  List<UpdateEnvelope> take(ClientId c);
}
