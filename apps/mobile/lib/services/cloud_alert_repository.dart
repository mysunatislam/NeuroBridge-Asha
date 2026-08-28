import 'dart:async';
import 'dart:convert';

import 'package:fingerspeak_mobile/data/cloud_api_client.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class CloudAlertRepository extends ChangeNotifier {
  CloudAlertRepository({
    required CloudApiClient apiClient,
  }) : _apiClient = apiClient;

  final CloudApiClient _apiClient;
  final List<CloudAlert> _alerts = [];
  final List<RemoteDevice> _remoteDevices = [];
  String? _profileId;
  bool _loading = false;
  WebSocketChannel? _channel;
  StreamSubscription? _socketSub;
  Timer? _pollTimer;

  List<CloudAlert> get alerts => List.unmodifiable(_alerts);
  List<RemoteDevice> get remoteDevices => List.unmodifiable(_remoteDevices);
  bool get isLoading => _loading;
  String? get currentProfileId => _profileId;

  Future<void> connectProfile(String profileId) async {
    final cleaned = profileId.trim();
    if (cleaned.isEmpty) return;
    _profileId = cleaned;
    await refresh();
    _startSocket();
    _startPolling();
  }

  Future<void> refresh() async {
    if (_profileId == null) return;
    _loading = true;
    notifyListeners();

    try {
      final fetchedAlerts = await _apiClient.loadCaregiverAlerts(_profileId!);
      _alerts.clear();
      _alerts.addAll(fetchedAlerts);
    } catch (_) {}

    try {
      final devices = await _apiClient.loadRemoteDevices(_profileId!);
      _remoteDevices.clear();
      _remoteDevices.addAll(devices);
    } catch (_) {}

    _loading = false;
    notifyListeners();
  }

  void _startSocket() {
    if (_profileId == null) return;
    _socketSub?.cancel();
    _channel?.sink.close();

    try {
      final uri = _apiClient.caregiverSocketUri(_profileId!);
      _channel = WebSocketChannel.connect(uri);
      _socketSub = _channel?.stream.listen((message) {
        try {
          final decoded = jsonDecode(message.toString());
          if (decoded is Map<String, dynamic>) {
            final alert = CloudAlert.fromJson(decoded);
            _alerts.removeWhere((a) => a.id == alert.id);
            _alerts.insert(0, alert);
            notifyListeners();
          }
        } catch (_) {}
      }, onError: (_) {});
    } catch (_) {}
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(refresh());
    });
  }

  Future<void> acknowledgeAlert(String alertId) async {
    try {
      await _apiClient.updateCaregiverAlert(alertId, 'acknowledge');
      final index = _alerts.indexWhere((a) => a.id == alertId);
      if (index != -1) {
        final current = _alerts[index];
        _alerts[index] = CloudAlert(
          id: current.id,
          profileId: current.profileId,
          sessionId: current.sessionId,
          sourceEventId: current.sourceEventId,
          severity: current.severity,
          message: current.message,
          status: 'acknowledged',
          createdAt: current.createdAt,
          acknowledgedAt: DateTime.now().toUtc().toIso8601String(),
          acknowledgedBy: 'caregiver',
        );
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> resolveAlert(String alertId) async {
    try {
      await _apiClient.updateCaregiverAlert(alertId, 'resolve');
      final index = _alerts.indexWhere((a) => a.id == alertId);
      if (index != -1) {
        final current = _alerts[index];
        _alerts[index] = CloudAlert(
          id: current.id,
          profileId: current.profileId,
          sessionId: current.sessionId,
          sourceEventId: current.sourceEventId,
          severity: current.severity,
          message: current.message,
          status: 'resolved',
          createdAt: current.createdAt,
          acknowledgedAt: current.acknowledgedAt,
          acknowledgedBy: current.acknowledgedBy,
          resolvedAt: DateTime.now().toUtc().toIso8601String(),
        );
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> sendCaptionToDevice(String deviceId, String text) async {
    await _apiClient.sendRemoteDeviceCaption(deviceId, text);
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _socketSub?.cancel();
    _channel?.sink.close();
    super.dispose();
  }
}
