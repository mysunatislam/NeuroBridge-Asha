import 'dart:async';
import 'package:fingerspeak_mobile/data/cloud_api_client.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CloudSyncService extends ChangeNotifier {
  CloudSyncService({
    required SharedPreferences preferences,
    required CloudApiClient apiClient,
  })  : _preferences = preferences,
        _apiClient = apiClient {
    _loadState();
  }

  static const _profileIdKey = 'cloud.remote_profile_id';
  static const _sessionIdKey = 'cloud.remote_session_id';
  static const _eventSyncConsentKey = 'cloud.consent.event_sync';
  static const _caregiverAlertsConsentKey = 'cloud.consent.caregiver_alerts';

  final SharedPreferences _preferences;
  final CloudApiClient _apiClient;

  String? _remoteProfileId;
  String? _remoteSessionId;
  bool _consentToEventSync = true;
  bool _consentToCaregiverAlerts = true;
  bool _syncing = false;
  String? _lastSyncError;

  String? get remoteProfileId => _remoteProfileId;
  String? get remoteSessionId => _remoteSessionId;
  bool get consentToEventSync => _consentToEventSync;
  bool get consentToCaregiverAlerts => _consentToCaregiverAlerts;
  bool get isSyncing => _syncing;
  String? get lastSyncError => _lastSyncError;

  void _loadState() {
    _remoteProfileId = _preferences.getString(_profileIdKey);
    _remoteSessionId = _preferences.getString(_sessionIdKey);
    _consentToEventSync = _preferences.getBool(_eventSyncConsentKey) ?? true;
    _consentToCaregiverAlerts =
        _preferences.getBool(_caregiverAlertsConsentKey) ?? true;
  }

  Future<void> setConsent({
    bool? consentToEventSync,
    bool? consentToCaregiverAlerts,
  }) async {
    if (consentToEventSync != null) {
      _consentToEventSync = consentToEventSync;
      await _preferences.setBool(_eventSyncConsentKey, consentToEventSync);
    }
    if (consentToCaregiverAlerts != null) {
      _consentToCaregiverAlerts = consentToCaregiverAlerts;
      await _preferences.setBool(
          _caregiverAlertsConsentKey, consentToCaregiverAlerts);
    }
    notifyListeners();

    if (_remoteProfileId != null) {
      try {
        await _apiClient.updateConsent(
          _remoteProfileId!,
          analyticsConsent: _consentToEventSync,
          caregiverAlertsConsent: _consentToCaregiverAlerts,
        );
      } catch (e) {
        _lastSyncError = '$e';
      }
    }
  }

  Future<void> ensureLinked() async {
    if (_syncing) return;
    _syncing = true;
    _lastSyncError = null;
    notifyListeners();

    try {
      if (_remoteProfileId == null) {
        final profileId = await _apiClient.createRemoteProfile(
          analyticsConsent: _consentToEventSync,
          caregiverAlertsConsent: _consentToCaregiverAlerts,
        );
        _remoteProfileId = profileId;
        await _preferences.setString(_profileIdKey, profileId);
      }

      if (_remoteProfileId != null) {
        final sessionId =
            await _apiClient.startRemoteSession(_remoteProfileId!);
        _remoteSessionId = sessionId;
        await _preferences.setString(_sessionIdKey, sessionId);
      }
    } catch (e) {
      _lastSyncError = '$e';
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> broadcastCaregiverAlert(String message, {String severity = 'routine'}) async {
    if (!_consentToCaregiverAlerts) return;
    if (_remoteProfileId == null || _remoteSessionId == null) {
      await ensureLinked();
    }
    if (_remoteProfileId != null && _remoteSessionId != null) {
      try {
        await _apiClient.sendCaregiverAlert(
          profileId: _remoteProfileId!,
          sessionId: _remoteSessionId!,
          message: message,
          severity: severity,
        );
      } catch (e) {
        _lastSyncError = '$e';
      }
    }
  }

  Future<void> unlinkProfile() async {
    _remoteProfileId = null;
    _remoteSessionId = null;
    await _preferences.remove(_profileIdKey);
    await _preferences.remove(_sessionIdKey);
    notifyListeners();
  }
}
