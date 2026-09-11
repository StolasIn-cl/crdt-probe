import 'package:flutter_test/flutter_test.dart';
import 'package:yjs_probe/driver/script_driver.dart';

void main() {
  test('a normal step is recorded in the trace after it completes', () async {
    final driver = ScriptDriver();

    await driver.step('do the thing', () async {});

    expect(driver.trace, ['do the thing']);
  });

  test('a throwing step still leaves its label in the trace, marked, and rethrows', () async {
    final driver = ScriptDriver();

    await expectLater(
      () => driver.step('do the thing', () async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );

    expect(driver.trace, hasLength(1));
    expect(driver.trace.single, contains('do the thing'));
    expect(driver.trace.single, contains('THREW'));
    expect(driver.trace.single, contains('boom'));
  });
}
