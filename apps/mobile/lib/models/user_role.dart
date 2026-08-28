import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum UserRole {
  patient,
  caregiver,
}

class UserRoleRepository extends ChangeNotifier {
  UserRoleRepository(this._preferences);

  static const _key = 'fingerspeak.user_role';
  final SharedPreferences _preferences;

  UserRole? load() {
    final raw = _preferences.getString(_key);
    if (raw == null || raw.isEmpty) return null;
    return UserRole.values.cast<UserRole?>().firstWhere(
          (role) => role?.name == raw,
          orElse: () => null,
        );
  }

  Future<void> save(UserRole role) async {
    await _preferences.setString(_key, role.name);
    notifyListeners();
  }

  Future<void> clear() async {
    await _preferences.remove(_key);
    notifyListeners();
  }
}
