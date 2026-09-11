import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

class CloudApiException implements Exception {
  const CloudApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CloudAlert {
  const CloudAlert({
    required this.id,
    required this.profileId,
    required this.sessionId,
    required this.sourceEventId,
    required this.severity,
    required this.message,
    required this.status,
    required this.createdAt,
    this.acknowledgedAt,
    this.acknowledgedBy,
    this.resolvedAt,
  });

  final String id;
  final String profileId;
  final String sessionId;
  final String sourceEventId;
  final String severity; // "routine" | "urgent" | "emergency"
  final String message;
  final String status; // "pending" | "acknowledged" | "resolved"
  final String createdAt;
  final String? acknowledgedAt;
  final String? acknowledgedBy;
  final String? resolvedAt;

  factory CloudAlert.fromJson(Map<String, dynamic> json) => CloudAlert(
        id: json['id'] as String? ?? '',
        profileId: json['profile_id'] as String? ?? '',
        sessionId: json['session_id'] as String? ?? '',
        sourceEventId: json['source_event_id'] as String? ?? '',
        severity: json['severity'] as String? ?? 'routine',
        message: json['message'] as String? ?? '',
        status: json['status'] as String? ?? 'pending',
        createdAt: json['created_at'] as String? ?? '',
        acknowledgedAt: json['acknowledged_at'] as String?,
        acknowledgedBy: json['acknowledged_by'] as String?,
        resolvedAt: json['resolved_at'] as String?,
      );
}

class RemoteDeviceState {
  const RemoteDeviceState({
    required this.sequence,
    required this.observedAt,
    required this.lastSeenAt,
    this.piBatteryPercent,
    this.wheelchairBatteryPercent,
    this.wheelchairStatus = 'unknown',
    this.cameraStatus = 'unknown',
    this.displayStatus = 'unknown',
    this.transport = 'unknown',
  });

  final int sequence;
  final String observedAt;
  final String lastSeenAt;
  final double? piBatteryPercent;
  final double? wheelchairBatteryPercent;
  final String wheelchairStatus;
  final String cameraStatus;
  final String displayStatus;
  final String transport;

  factory RemoteDeviceState.fromJson(Map<String, dynamic> json) =>
      RemoteDeviceState(
        sequence: json['sequence'] as int? ?? 0,
        observedAt: json['observed_at'] as String? ?? '',
        lastSeenAt: json['last_seen_at'] as String? ?? '',
        piBatteryPercent: (json['pi_battery_percent'] as num?)?.toDouble(),
        wheelchairBatteryPercent:
            (json['wheelchair_battery_percent'] as num?)?.toDouble(),
        wheelchairStatus: json['wheelchair_status'] as String? ?? 'unknown',
        cameraStatus: json['camera_status'] as String? ?? 'unknown',
        displayStatus: json['display_status'] as String? ?? 'unknown',
        transport: json['transport'] as String? ?? 'unknown',
      );
}

class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.profileId,
    required this.name,
    required this.enabled,
    required this.online,
    this.lastState,
  });

  final String id;
  final String profileId;
  final String name;
  final bool enabled;
  final bool online;
  final RemoteDeviceState? lastState;

  factory RemoteDevice.fromJson(Map<String, dynamic> json) => RemoteDevice(
        id: json['id'] as String? ?? '',
        profileId: json['profile_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? false,
        online: json['online'] as bool? ?? false,
        lastState: json['last_state'] is Map<String, dynamic>
            ? RemoteDeviceState.fromJson(
                json['last_state'] as Map<String, dynamic>)
            : null,
      );
}

class CloudApiClient {
  CloudApiClient({
    required Uri baseUri,
    http.Client? client,
  })  : _baseUri = baseUri,
        _client = client ?? http.Client();

  final Uri _baseUri;
  final http.Client _client;
  static const _uuid = Uuid();

  Uri _resolve(String path) {
    final normalized = _baseUri.path.endsWith('/')
        ? _baseUri
        : _baseUri.replace(path: '${_baseUri.path}/');
    return normalized.resolve(path.startsWith('/') ? path.substring(1) : path);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final response = await _client
        .post(
          _resolve(path),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    throw CloudApiException('API error ${response.statusCode}: ${response.body}');
  }

  Future<dynamic> _get(String path) async {
    final response = await _client.get(
      _resolve(path),
      headers: {'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body);
    }
    throw CloudApiException('API error ${response.statusCode}');
  }

  Future<String> createRemoteProfile({
    bool analyticsConsent = true,
    bool caregiverAlertsConsent = true,
  }) async {
    final res = await _post('profiles', {
      'display_name': 'FingerSpeak Mobile Profile',
      'locale': 'en-US',
      'consent_version': 'prototype-v1',
      'consent_granted_at': DateTime.now().toUtc().toIso8601String(),
      'analytics_consent': analyticsConsent,
      'caregiver_alerts_consent': caregiverAlertsConsent,
      'model_sync_consent': false,
      'vocabulary': [],
    });
    return res['id'] as String;
  }

  Future<String> startRemoteSession(String profileId) async {
    final clientSessionId = _uuid.v4();
    final res = await _post('sessions', {
      'profile_id': profileId,
      'client_session_id': clientSessionId,
      'device_id': 'mobile-flutter',
      'client_version': 'flutter-1.0.0',
      'inference_location': 'on_device',
      'started_at': DateTime.now().toUtc().toIso8601String(),
    });
    return res['id'] as String;
  }

  Future<void> updateConsent(
    String profileId, {
    required bool analyticsConsent,
    required bool caregiverAlertsConsent,
  }) async {
    final response = await _client.patch(
      _resolve('profiles/$profileId'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'analytics_consent': analyticsConsent,
        'caregiver_alerts_consent': caregiverAlertsConsent,
        'model_sync_consent': false,
      }),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudApiException('Failed to update consent: ${response.statusCode}');
    }
  }

  Future<void> sendCaregiverAlert({
    required String profileId,
    required String sessionId,
    required String message,
    required String severity,
  }) async {
    await _post('events/caregiver-alerts', {
      'profile_id': profileId,
      'session_id': sessionId,
      'client_event_id': _uuid.v4(),
      'severity': severity,
      'message': message,
      'requested_at': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<List<CloudAlert>> loadCaregiverAlerts(String profileId) async {
    final res = await _get('events/caregiver-alerts?profile_id=${Uri.encodeComponent(profileId)}&limit=100');
    if (res is List) {
      return res
          .whereType<Map<String, dynamic>>()
          .map(CloudAlert.fromJson)
          .toList();
    }
    return [];
  }

  Future<void> updateCaregiverAlert(String alertId, String action) async {
    await _post('events/caregiver-alerts/$alertId/$action', {});
  }

  Future<List<RemoteDevice>> loadRemoteDevices(String profileId) async {
    final res = await _get('devices?profile_id=${Uri.encodeComponent(profileId)}&limit=20');
    if (res is List) {
      return res
          .whereType<Map<String, dynamic>>()
          .map(RemoteDevice.fromJson)
          .toList();
    }
    return [];
  }

  Future<void> sendRemoteDeviceCaption(String deviceId, String text) async {
    await _post('devices/$deviceId/captions', {
      'client_message_id': _uuid.v4(),
      'text': text.trim(),
      'locale': 'en-US',
    });
  }

  Future<void> grantCaregiver(String profileId, String caregiverSubject) async {
    final response = await _client.put(
      _resolve('profiles/$profileId/caregivers'),
      headers: {
        'Accept': 'application/json',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({'caregiver_subject': caregiverSubject}),
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CloudApiException('Failed to grant caregiver: ${response.statusCode}');
    }
  }

  Uri caregiverSocketUri(String profileId) {
    final scheme = _baseUri.scheme == 'https' ? 'wss' : 'ws';
    final normalized = _baseUri.path.endsWith('/')
        ? _baseUri.path
        : '${_baseUri.path}/';
    return _baseUri.replace(
      scheme: scheme,
      path: '${normalized}events/caregiver-alerts/ws',
      queryParameters: {'profile_id': profileId},
    );
  }

  void close() => _client.close();
}
