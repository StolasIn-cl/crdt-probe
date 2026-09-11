/// What a [CrdtRuntime] can be asked to show. Declared rather than discovered,
/// because a scenario that cannot see the thing it checks must report
/// `Unobservable` and never `Passed`.
enum Capability {
  decodeUpdate,
  enumerateTombstones,
  readUndoStackItems,
  enumeratePerCharacterIdentity,
  readStateVector,
  enumerateFormatMarkers,
  countPendingStructs,
}

class CapabilitySet {
  const CapabilitySet.of(this._values);

  final Set<Capability> _values;

  bool has(Capability c) => _values.contains(c);

  Set<Capability> missingFrom(Set<Capability> required) =>
      required.difference(_values);

  Set<Capability> get values => Set.unmodifiable(_values);
}
