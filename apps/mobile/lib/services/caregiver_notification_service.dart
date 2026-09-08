import 'dart:async';
import 'dart:convert';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

enum AlertUrgency { normal, warning, emergency }

class CaregiverAlert {
  const CaregiverAlert({
    required this.id,
    required this.title,
    required this.message,
    required this.urgency,
    required this.timestamp,
    this.signalKind,
  });

  final String id;
  final String title;
  final String message;
  final AlertUrgency urgency;
  final DateTime timestamp;
  final PatientSignalKind? signalKind;

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'message': message,
        'urgency': urgency.name,
        'timestamp': timestamp.toIso8601String(),
        'signalKind': signalKind?.name,
      };

  factory CaregiverAlert.fromJson(Map<String, Object?> json) {
    return CaregiverAlert(
      id: json['id'] as String,
      title: json['title'] as String,
      message: json['message'] as String,
      urgency: AlertUrgency.values.byName(json['urgency'] as String),
      timestamp: DateTime.parse(json['timestamp'] as String),
      signalKind: json['signalKind'] != null
          ? PatientSignalKind.values.byName(json['signalKind'] as String)
          : null,
    );
  }
}

class CaregiverNotificationService {
  CaregiverNotificationService(
    this._preferences, {
    FlutterLocalNotificationsPlugin? notifications,
  }) : _notifications = notifications ?? FlutterLocalNotificationsPlugin();

  static const _alertsKey = 'fingerspeak.caregiver.recent_alerts';
  static const _uuid = Uuid();
  final SharedPreferences _preferences;
  final FlutterLocalNotificationsPlugin _notifications;
  final _alertsController = StreamController<CaregiverAlert>.broadcast();
  final List<CaregiverAlert> _recentAlerts = [];
  bool _initialized = false;
  int _nextNotificationId = 1000;

  Stream<CaregiverAlert> get alerts => _alertsController.stream;
  List<CaregiverAlert> get recentAlerts => List.unmodifiable(_recentAlerts);

  Future<void> initialize() async {
    if (_initialized) return;
    _loadPersistedAlerts();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwinSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(
      android: androidSettings,
      iOS: darwinSettings,
    );

    try {
      await _notifications.initialize(settings);
    } on Object {
      // Local notification failures (e.g. unsupported desktop/test) must not crash the app.
    }
    _initialized = true;
  }

  void _loadPersistedAlerts() {
    final raw = _preferences.getString(_alertsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List<Object?>)
          .whereType<Map<String, Object?>>()
          .map(CaregiverAlert.fromJson);
      _recentAlerts.addAll(list);
    } on Object {
      // Ignore corrupted cache.
    }
  }

  Future<void> _saveAlerts() async {
    while (_recentAlerts.length > 50) {
      _recentAlerts.removeLast();
    }
    await _preferences.setString(
      _alertsKey,
      jsonEncode(_recentAlerts.map((a) => a.toJson()).toList()),
    );
  }

  Future<void> notifyPatientSpoken(
    String phrase, {
    PatientSignalKind? signalKind,
  }) async {
    final alert = CaregiverAlert(
      id: _uuid.v4(),
      title: 'Patient Spoke',
      message: phrase,
      urgency: AlertUrgency.normal,
      timestamp: DateTime.now(),
      signalKind: signalKind,
    );
    await _dispatchAlert(alert);
  }

  Future<void> notifyEmergency(
    String title,
    String message, {
    PatientSignalKind? signalKind,
    AlertUrgency urgency = AlertUrgency.emergency,
  }) async {
    final alert = CaregiverAlert(
      id: _uuid.v4(),
      title: title,
      message: message,
      urgency: urgency,
      timestamp: DateTime.now(),
      signalKind: signalKind,
    );
    await _dispatchAlert(alert);
  }

  Future<void> _dispatchAlert(CaregiverAlert alert) async {
    _recentAlerts.insert(0, alert);
    unawaited(_saveAlerts());
    _alertsController.add(alert);

    try {
      const androidDetails = AndroidNotificationDetails(
        'fingerspeak_caregiver_alerts',
        'Patient Alerts',
        channelDescription: 'Real-time notifications for patient vocal and emergency signals.',
        importance: Importance.max,
        priority: Priority.high,
        showWhen: true,
      );
      const notificationDetails = NotificationDetails(android: androidDetails);
      await _notifications.show(
        _nextNotificationId++,
        alert.title,
        alert.message,
        notificationDetails,
      );
    } on Object {
      // Best-effort notification delivery.
    }
  }

  Future<void> clearAlerts() async {
    _recentAlerts.clear();
    await _preferences.remove(_alertsKey);
  }

  Future<void> restoreAlerts(List<CaregiverAlert> alerts) async {
    _recentAlerts.clear();
    _recentAlerts.addAll(alerts);
    await _saveAlerts();
  }

  Future<void> dispose() async {
    await _alertsController.close();
  }
}
