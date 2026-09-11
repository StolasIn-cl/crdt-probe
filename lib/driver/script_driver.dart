/// Wraps a scripted sequence so every step is named in a trace. The trace is
/// what a measurement report quotes, so a scenario's evidence is the steps it
/// actually took rather than a prose summary.
class ScriptDriver {
  final List<String> _trace = [];

  List<String> get trace => List.unmodifiable(_trace);

  Future<void> step(String label, Future<void> Function() body) async {
    try {
      await body();
      _trace.add(label);
    } catch (e) {
      _trace.add('$label  [THREW: $e]');
      rethrow;
    }
  }

  void note(String observation) => _trace.add('  -> $observation');
}
