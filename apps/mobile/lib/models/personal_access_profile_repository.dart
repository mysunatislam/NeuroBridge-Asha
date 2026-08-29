// personal_access_profile_repository.dart
// Persistent repository for PersonalAccessProfile using SharedPreferences.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'personal_access_profile.dart';

class PersonalAccessProfileRepository extends ChangeNotifier {
  PersonalAccessProfileRepository(this._preferences);

  final SharedPreferences _preferences;
  static const _key = 'neurobridge_personal_access_profile';

  PersonalAccessProfile? _cachedProfile;

  PersonalAccessProfile? load() {
    if (_cachedProfile != null) return _cachedProfile;
    final raw = _preferences.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _cachedProfile = PersonalAccessProfile.fromJson(json);
      return _cachedProfile;
    } catch (_) {
      return null;
    }
  }

  Future<void> save(PersonalAccessProfile profile) async {
    _cachedProfile = profile;
    final raw = jsonEncode(profile.toJson());
    await _preferences.setString(_key, raw);
    notifyListeners();
  }

  Future<void> clear() async {
    _cachedProfile = null;
    await _preferences.remove(_key);
    notifyListeners();
  }
}
