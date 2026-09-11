import 'dart:convert';
import 'dart:typed_data';

/// Converts values crossing the probe's diagnostics boundary into values that
/// [jsonEncode] can serialize without losing binary evidence.
Object? toJsonSafe(Object? value) {
  if (value == null || value is String || value is bool) return value;
  if (value is num) {
    return value.isFinite ? value : value.toString();
  }
  if (value is Uint8List) {
    return {
      'type': 'Uint8List',
      'byteLength': value.length,
      'base64': base64Encode(value),
    };
  }
  if (value is List<int>) {
    final bytes = Uint8List.fromList(value);
    return {
      'type': 'bytes',
      'byteLength': bytes.length,
      'base64': base64Encode(bytes),
    };
  }
  if (value is Map) {
    return {
      for (final entry in value.entries)
        '${entry.key}': toJsonSafe(entry.value),
    };
  }
  if (value is Iterable) return value.map(toJsonSafe).toList(growable: false);
  return '$value';
}
