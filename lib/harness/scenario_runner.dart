import '../driver/script_driver.dart';
import '../runtime/crdt_runtime.dart';
import 'scenario.dart';

class ScenarioRunner {
  final Map<String, List<String>> _traces = {};

  /// Traces from the most recent [runAll], or from the [run] calls since it.
  ///
  /// Deliberately reset by [runAll] rather than accumulated. Traces are keyed by
  /// scenario id alone, so probing one scenario set against two runtimes — which
  /// is the comparison this project exists to make — would otherwise let the
  /// second run silently overwrite the first, and a report labelled with one
  /// runtime would quote the other's evidence. A mixture must be unreachable,
  /// not merely discouraged. This does mean a run's report must be rendered
  /// before the next run starts.
  Map<String, List<String>> get traces => Map.unmodifiable(_traces);

  /// The capability gate is checked *before* the body runs. A scenario cannot
  /// pass by failing to look.
  Future<ScenarioOutcome> run(Scenario s, CrdtRuntime runtime) async {
    final missing = runtime.capabilities.missingFrom(s.requires);
    if (missing.isNotEmpty) {
      return Unobservable(missing: missing, runtimeName: runtime.name);
    }

    final driver = ScriptDriver();
    try {
      final outcome = await s.body(ScenarioContext(runtime: runtime, driver: driver));
      _traces[s.id] = driver.trace;
      return outcome;
    } catch (e, st) {
      _traces[s.id] = driver.trace;
      return Failed(reason: '$e\n$st');
    }
  }

  Future<Map<String, ScenarioOutcome>> runAll(
    List<Scenario> scenarios,
    CrdtRuntime runtime,
  ) async {
    _traces.clear();
    final results = <String, ScenarioOutcome>{};
    for (final s in scenarios) {
      results[s.id] = await run(s, runtime);
    }
    return results;
  }
}
