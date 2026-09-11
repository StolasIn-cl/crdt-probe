import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yjs_probe/core/ids.dart';
import 'package:yjs_probe/runtime/yrs/yrs_runtime.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('the test-only Yrs DLL loads and opens a pinned client document', () async {
    final runtime = await YrsRuntime.create();
    const client = ClientId(7);
    await runtime.open(client);
    expect(runtime.name, 'yrs-ffi-0.27.3');
    expect((await runtime.projection(client)).clientId, client);
    await runtime.close(client);
  });
}
