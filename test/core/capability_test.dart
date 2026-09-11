import 'package:flutter_test/flutter_test.dart';
import 'package:yjs_probe/core/capability.dart';

void main() {
  test('a capability set reports what a requirement is missing', () {
    final set = CapabilitySet.of({Capability.readStateVector, Capability.decodeUpdate});

    expect(set.has(Capability.decodeUpdate), isTrue);
    expect(set.has(Capability.enumerateTombstones), isFalse);
    expect(
      set.missingFrom({Capability.decodeUpdate, Capability.enumerateTombstones}),
      {Capability.enumerateTombstones},
    );
  });

  test('a requirement fully covered reports nothing missing', () {
    final set = CapabilitySet.of({Capability.decodeUpdate});
    expect(set.missingFrom({Capability.decodeUpdate}), isEmpty);
  });
}
