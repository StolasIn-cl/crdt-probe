import 'ids.dart';

class ObjectProjection {
  const ObjectProjection({
    required this.kind,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.rotation,
    required this.z,
    this.text,
    this.delta,
    this.src,
  });

  final String kind;
  final double x;
  final double y;
  final double w;
  final double h;
  final double rotation;
  final double z;

  /// Plain text of a title, absent for an image.
  final String? text;

  /// `Y.Text.toDelta()` — the formatting view. This is the shape `yffi` also
  /// exposes (chunk-with-format reads), so it is portable across runtimes.
  final List<Map<String, Object?>>? delta;

  final String? src;

  Map<String, Object?> toJson() => {
        'kind': kind,
        'x': x,
        'y': y,
        'w': w,
        'h': h,
        'rotation': rotation,
        'z': z,
        'text': text,
        'delta': delta,
        'src': src,
      };

  static ObjectProjection fromJson(Map<String, dynamic> j) => ObjectProjection(
        kind: j['kind'] as String,
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        w: (j['w'] as num).toDouble(),
        h: (j['h'] as num).toDouble(),
        rotation: (j['rotation'] as num).toDouble(),
        z: (j['z'] as num).toDouble(),
        text: j['text'] as String?,
        delta: (j['delta'] as List?)?.cast<Map<String, Object?>>(),
        src: j['src'] as String?,
      );
}

class DocProjection {
  const DocProjection({
    required this.clientId,
    required this.objects,
    required this.stateVectorB64,
  });

  final ClientId clientId;
  final Map<ObjectId, ObjectProjection> objects;
  final String stateVectorB64;

  Map<String, Object?> toJson() => {
        'clientId': clientId.value,
        'stateVectorB64': stateVectorB64,
        'objects': {
          for (final entry in objects.entries) entry.key.value: entry.value.toJson(),
        },
      };

  static DocProjection fromJson(Map<String, dynamic> j) => DocProjection(
        clientId: ClientId(j['clientId'] as int),
        stateVectorB64: j['stateVectorB64'] as String,
        objects: {
          for (final e in (j['objects'] as Map<String, dynamic>).entries)
            ObjectId(e.key): ObjectProjection.fromJson(e.value as Map<String, dynamic>),
        },
      );
}
