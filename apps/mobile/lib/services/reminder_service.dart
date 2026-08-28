import 'package:fingerspeak_mobile/models/care_routine_settings.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalReminderService {
  LocalReminderService(
    this._preferences, {
    FlutterLocalNotificationsPlugin? notifications,
  }) : _notifications = notifications ?? FlutterLocalNotificationsPlugin() {
    _settings = _loadSettings();
  }

  static const _settingsKey = 'reminders.care_routines.settings';
  static const _waterEnabledKey = 'reminders.water.enabled';
  static const _waterNotificationId = 4101;
  static const _checkInNotificationId = 4201;

  final SharedPreferences _preferences;
  final FlutterLocalNotificationsPlugin _notifications;
  late CareRoutineSettings _settings;

  CareRoutineSettings get settings => _settings;

  bool get waterRemindersEnabled => _settings.hydration.enabled;

  CareRoutineSettings _loadSettings() {
    final raw = _preferences.getString(_settingsKey);
    if (raw != null) {
      return CareRoutineSettings.deserialize(raw);
    }
    final legacyWater = _preferences.getBool(_waterEnabledKey);
    if (legacyWater != null) {
      return CareRoutineSettings(
        hydration: RoutineDefinition(enabled: legacyWater),
      );
    }
    return const CareRoutineSettings();
  }

  Future<void> saveSettings(CareRoutineSettings updated) async {
    _settings = updated;
    await _preferences.setString(_settingsKey, updated.serialize());
    await _preferences.setBool(_waterEnabledKey, updated.hydration.enabled);
    if (updated.hydration.enabled) {
      await _scheduleHourlyWaterReminder();
    } else {
      await _notifications.cancel(_waterNotificationId);
    }
  }

  Future<void> initialize() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    await _notifications.initialize(
      const InitializationSettings(android: android, iOS: ios),
    );
    await _notifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
    if (waterRemindersEnabled) await _scheduleHourlyWaterReminder();
  }

  Future<void> setWaterRemindersEnabled(bool enabled) async {
    final updated = _settings.copyWith(
      hydration: _settings.hydration.copyWith(enabled: enabled),
    );
    await saveSettings(updated);
  }

  Future<void> remindNow([String? customMessage]) => _notifications.show(
        _waterNotificationId + 1,
        'A gentle water reminder',
        customMessage ?? _settings.hydrationMessage,
        _details,
      );

  Future<void> checkInNow([String? customMessage]) => _notifications.show(
        _checkInNotificationId + 1,
        'Asha Check-In',
        customMessage ??
            (_settings.checkInMessages.isNotEmpty
                ? _settings.checkInMessages.first
                : 'Asha is right here with you.'),
        _details,
      );

  Future<void> _scheduleHourlyWaterReminder() =>
      _notifications.periodicallyShow(
        _waterNotificationId,
        'Asha is checking in',
        _settings.hydrationMessage,
        RepeatInterval.hourly,
        _details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'fingerspeak_water',
      'Care routines',
      channelDescription: 'Gentle, patient-controlled hydration & wellness reminders',
      importance: Importance.high,
      priority: Priority.high,
    ),
    iOS: DarwinNotificationDetails(),
  );
}

