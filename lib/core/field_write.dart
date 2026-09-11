import 'ids.dart';

/// One scalar field mutation inside a runtime transaction.
class FieldWrite {
  const FieldWrite(this.objectId, this.key, this.value);

  final ObjectId objectId;
  final String key;
  final num value;

  Map<String, Object?> toJson() => {
        'objectId': objectId.value,
        'key': key,
        'value': value,
      };
}
