import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PatientAccessMethod {
  handGestures,
  faceEyesAndHead;

  String get displayName => switch (this) {
        PatientAccessMethod.handGestures => 'Finger and hand gestures',
        PatientAccessMethod.faceEyesAndHead => 'Face, eyes, and head',
      };
}

class PatientAccessMethodRepository extends ChangeNotifier {
  PatientAccessMethodRepository(this._preferences);

  static const _key = 'patient.access_method';
  final SharedPreferences _preferences;

  PatientAccessMethod? load() {
    final raw = _preferences.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    return PatientAccessMethod.values.cast<PatientAccessMethod?>().firstWhere(
          (method) => method?.name == raw,
          orElse: () => null,
        );
  }

  Future<void> save(PatientAccessMethod method) async {
    await _preferences.setString(_key, method.name);
    notifyListeners();
  }

  Future<void> clear() async {
    await _preferences.remove(_key);
    notifyListeners();
  }
}
