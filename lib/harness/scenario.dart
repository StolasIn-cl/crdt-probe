import '../core/capability.dart';
import '../driver/script_driver.dart';
import '../runtime/crdt_runtime.dart';
import '../runtime/undo_runtime.dart';

/// Three outcomes, not two. `Unobservable` exists because this probe's most
/// likely failure is a clean false pass on a runtime that could not see the
/// thing being checked (ticket 17 §9).
sealed class ScenarioOutcome {
  const ScenarioOutcome();
}

final class Passed extends ScenarioOutcome {
  const Passed({required this.evidence});
  final String evidence;
}

final class Failed extends ScenarioOutcome {
  const Failed({required this.reason});
  final String reason;
}

final class Unobservable extends ScenarioOutcome {
  const Unobservable({required this.missing, required this.runtimeName});
  final Set<Capability> missing;
  final String runtimeName;
}

class ScenarioContext {
  const ScenarioContext({required this.runtime, required this.driver});
  final CrdtRuntime runtime;
  final ScriptDriver driver;

  UndoRuntime get undo {
    final value = runtime;
    if (value is UndoRuntime) return value as UndoRuntime;
    throw StateError('${runtime.name} does not implement UndoRuntime');
  }
}

class Scenario {
  const Scenario({
    required this.id,
    required this.title,
    required this.targets,
    required this.requires,
    required this.body,
  });

  final String id;
  final String title;

  /// Which recorded claim this scenario is aimed at, quoted so a report can
  /// say what a result is evidence *about*.
  final String targets;

  final Set<Capability> requires;
  final Future<ScenarioOutcome> Function(ScenarioContext) body;
}
