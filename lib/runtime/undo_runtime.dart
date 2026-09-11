import '../core/ids.dart';

/// Undo/redo controls shared by the Yjs and Yrs probe runtimes.
///
/// This is deliberately separate from [CrdtRuntime]: a runtime can project and
/// merge documents without exposing an undo implementation, and the scenario
/// runner must keep that distinction observable.
abstract interface class UndoRuntime {
  Future<void> setOperationOrigin(ClientId clientId, String origin);

  Future<void> setTrackedOrigins(ClientId clientId, Set<String> origins);

  Future<void> stopCapturing(ClientId clientId);

  Future<bool> undo(ClientId clientId);

  Future<bool> redo(ClientId clientId);

  Future<int> undoStackLength(ClientId clientId);

  Future<int> redoStackLength(ClientId clientId);
}
