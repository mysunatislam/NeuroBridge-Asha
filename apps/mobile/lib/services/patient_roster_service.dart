import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'local_peer_sync_service.dart';

enum PatientConnectionState { localLan, cloudOnly, disconnected }

class MonitoredPatient {
  MonitoredPatient({
    required this.id,
    required this.name,
    required this.roomNumber,
    required this.accessMethod,
    this.connectionState = PatientConnectionState.disconnected,
    this.ipAddress = '',
    this.httpPort = 41529,
    this.batteryPercent = 100,
    this.respirationBpm,
    this.lastSpokenPhrase,
    required this.lastSeen,
    this.isEmergency = false,
    List<String>? recentAlerts,
  }) : recentAlerts = recentAlerts ?? [];

  final String id;
  String name;
  String roomNumber;
  String accessMethod;
  PatientConnectionState connectionState;
  String ipAddress;
  int httpPort;
  int batteryPercent;
  double? respirationBpm;
  String? lastSpokenPhrase;
  DateTime lastSeen;
  bool isEmergency;
  final List<String> recentAlerts;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'roomNumber': roomNumber,
        'accessMethod': accessMethod,
        'ipAddress': ipAddress,
        'httpPort': httpPort,
        'batteryPercent': batteryPercent,
        'respirationBpm': respirationBpm,
        'lastSpokenPhrase': lastSpokenPhrase,
        'lastSeen': lastSeen.toIso8601String(),
        'isEmergency': isEmergency,
        'recentAlerts': recentAlerts,
      };

  factory MonitoredPatient.fromJson(Map<String, dynamic> json) {
    return MonitoredPatient(
      id: json['id'] as String? ?? 'p-${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Patient',
      roomNumber: json['roomNumber'] as String? ?? 'Ward',
      accessMethod: json['accessMethod'] as String? ?? 'Face & Eyes',
      ipAddress: json['ipAddress'] as String? ?? '',
      httpPort: (json['httpPort'] as num?)?.toInt() ?? 41529,
      batteryPercent: (json['batteryPercent'] as num?)?.toInt() ?? 100,
      respirationBpm: (json['respirationBpm'] as num?)?.toDouble(),
      lastSpokenPhrase: json['lastSpokenPhrase'] as String?,
      lastSeen: json['lastSeen'] != null
          ? DateTime.tryParse(json['lastSeen'] as String) ?? DateTime.now()
          : DateTime.now(),
      isEmergency: json['isEmergency'] as bool? ?? false,
      recentAlerts: (json['recentAlerts'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }
}

/// Caregiver Roster Service managing up to 20 monitored patients across local Wi-Fi & cloud.
class PatientRosterService extends ChangeNotifier {
  PatientRosterService({
    required this.preferences,
    required this.peerSync,
    this.autoStartHeartbeat = true,
  }) {
    _init();
  }

  final SharedPreferences preferences;
  final LocalPeerSyncService peerSync;
  final bool autoStartHeartbeat;

  static const _storageKey = 'neurobridge_patient_roster_v1';
  final List<MonitoredPatient> _patients = [];
  StreamSubscription<AshaPatientBeacon>? _beaconSub;
  Timer? _healthCheckTimer;

  List<MonitoredPatient> get patients => List.unmodifiable(_patients);

  int get emergencyCount => _patients.where((p) => p.isEmergency).length;

  int get localOnlineCount => _patients
      .where((p) => p.connectionState == PatientConnectionState.localLan)
      .length;

  void _init() {
    _loadFromStorage();
    if (_patients.isEmpty) {
      _seedClinicalRoster();
    }

    _beaconSub = peerSync.beacons.listen(_onBeaconReceived);

    // Periodic heartbeat check: mark patients offline if no beacon received for 10s
    if (autoStartHeartbeat) {
      _healthCheckTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        final now = DateTime.now();
        var changed = false;
        for (final p in _patients) {
          if (p.connectionState == PatientConnectionState.localLan &&
              now.difference(p.lastSeen) > const Duration(seconds: 10)) {
            p.connectionState = PatientConnectionState.disconnected;
            changed = true;
          }
        }
        if (changed) notifyListeners();
      });
    }
  }

  void _onBeaconReceived(AshaPatientBeacon beacon) {
    final idx = _patients.indexWhere((p) => p.id == beacon.patientId);

    if (idx >= 0) {
      final p = _patients[idx];
      p.name = beacon.name;
      p.roomNumber = beacon.roomNumber;
      p.accessMethod = beacon.accessMethod;
      p.connectionState = PatientConnectionState.localLan;
      p.ipAddress = beacon.ipAddress;
      p.httpPort = beacon.httpPort;
      p.batteryPercent = beacon.batteryPercent;
      p.respirationBpm = beacon.respirationBpm ?? p.respirationBpm;
      p.lastSeen = beacon.timestamp;
      p.isEmergency = beacon.isEmergency;
      if (beacon.lastSpokenPhrase != null && beacon.lastSpokenPhrase!.isNotEmpty) {
        p.lastSpokenPhrase = beacon.lastSpokenPhrase;
        p.recentAlerts.insert(0, '[${DateTime.now().toIso8601String().substring(11, 16)}] ${beacon.lastSpokenPhrase}');
        if (p.recentAlerts.length > 20) p.recentAlerts.removeLast();
      }
    } else {
      // New patient discovered on local Wi-Fi! Auto-add to roster
      final newPatient = MonitoredPatient(
        id: beacon.patientId,
        name: beacon.name,
        roomNumber: beacon.roomNumber,
        accessMethod: beacon.accessMethod,
        connectionState: PatientConnectionState.localLan,
        ipAddress: beacon.ipAddress,
        httpPort: beacon.httpPort,
        batteryPercent: beacon.batteryPercent,
        respirationBpm: beacon.respirationBpm,
        lastSpokenPhrase: beacon.lastSpokenPhrase,
        lastSeen: beacon.timestamp,
        isEmergency: beacon.isEmergency,
      );
      _patients.insert(0, newPatient);
    }

    _sortRoster();
    _saveToStorage();
    notifyListeners();
  }

  void _sortRoster() {
    // Priorities: Emergencies first, then local online, then others
    _patients.sort((a, b) {
      if (a.isEmergency && !b.isEmergency) return -1;
      if (!a.isEmergency && b.isEmergency) return 1;
      if (a.connectionState == PatientConnectionState.localLan &&
          b.connectionState != PatientConnectionState.localLan) {
        return -1;
      }
      if (a.connectionState != PatientConnectionState.localLan &&
          b.connectionState == PatientConnectionState.localLan) {
        return 1;
      }
      return a.roomNumber.compareTo(b.roomNumber);
    });
  }

  /// Manually add a patient to the monitoring roster
  Future<void> addPatient(MonitoredPatient patient) async {
    _patients.add(patient);
    _sortRoster();
    await _saveToStorage();
    notifyListeners();
  }

  /// Remove a patient from the roster
  Future<void> removePatient(String patientId) async {
    _patients.removeWhere((p) => p.id == patientId);
    await _saveToStorage();
    notifyListeners();
  }

  /// Acknowledge emergency SOS for a patient
  Future<void> acknowledgeEmergency(String patientId) async {
    final patient = _patients.firstWhere(
      (p) => p.id == patientId,
      orElse: () => throw StateError('Patient not found'),
    );
    patient.isEmergency = false;
    if (patient.ipAddress.isNotEmpty) {
      unawaited(peerSync.acknowledgeEmergency(
        targetIp: patient.ipAddress,
        targetPort: patient.httpPort,
      ));
    }
    _sortRoster();
    await _saveToStorage();
    notifyListeners();
  }

  /// Broadcast a text message to a specific patient's wheelchair screen
  Future<bool> sendDisplayMessageToPatient({
    required String patientId,
    required String message,
    String sender = 'Caregiver Hub',
  }) async {
    final patient = _patients.firstWhere((p) => p.id == patientId);
    if (patient.ipAddress.isNotEmpty &&
        patient.connectionState == PatientConnectionState.localLan) {
      return peerSync.sendRemoteDisplayMessage(
        targetIp: patient.ipAddress,
        targetPort: patient.httpPort,
        sender: sender,
        message: message,
      );
    }
    return false;
  }

  /// Broadcast a notification message to ALL monitored patients
  Future<int> broadcastToAllPatients(String message) async {
    var successCount = 0;
    for (final p in _patients) {
      if (p.connectionState == PatientConnectionState.localLan &&
          p.ipAddress.isNotEmpty) {
        final ok = await peerSync.sendRemoteDisplayMessage(
          targetIp: p.ipAddress,
          targetPort: p.httpPort,
          sender: 'Ward Broadcast',
          message: message,
        );
        if (ok) successCount++;
      }
    }
    return successCount;
  }

  void _loadFromStorage() {
    final raw = preferences.getString(_storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _patients.clear();
      for (final item in list) {
        _patients.add(MonitoredPatient.fromJson(item as Map<String, dynamic>));
      }
    } catch (e) {
      debugPrint('[PatientRoster] Could not load saved roster: $e');
    }
  }

  Future<void> _saveToStorage() async {
    try {
      final list = _patients.map((p) => p.toJson()).toList();
      await preferences.setString(_storageKey, jsonEncode(list));
    } catch (e) {
      debugPrint('[PatientRoster] Could not save roster: $e');
    }
  }

  /// Seeds clinical roster with realistic ward patients (12 beds) for immediate clinical evaluation
  void _seedClinicalRoster() {
    final now = DateTime.now();
    _patients.addAll([
      MonitoredPatient(
        id: 'patient-bed-101',
        name: 'Eleanor Vance',
        roomNumber: 'Bed 101 (ICU East)',
        accessMethod: '3D Hand Gestures',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.101',
        batteryPercent: 94,
        respirationBpm: 16.2,
        lastSpokenPhrase: 'I would like some water please',
        lastSeen: now,
      ),
      MonitoredPatient(
        id: 'patient-bed-102',
        name: 'Marcus Chen',
        roomNumber: 'Bed 102 (ICU East)',
        accessMethod: 'Face & Eye Gaze',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.102',
        batteryPercent: 78,
        respirationBpm: 19.5,
        lastSpokenPhrase: 'Adjust my pillow please',
        lastSeen: now.subtract(const Duration(seconds: 2)),
      ),
      MonitoredPatient(
        id: 'patient-bed-103',
        name: 'Sarah Jenkins',
        roomNumber: 'Bed 103 (Neuro Rehab)',
        accessMethod: 'Single-Switch Scan',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.103',
        batteryPercent: 88,
        respirationBpm: 17.0,
        lastSpokenPhrase: 'Yes',
        lastSeen: now.subtract(const Duration(seconds: 4)),
      ),
      MonitoredPatient(
        id: 'patient-bed-104',
        name: 'Arthur Pendelton',
        roomNumber: 'Bed 104 (Neuro Rehab)',
        accessMethod: 'Face & Eye Gaze',
        connectionState: PatientConnectionState.cloudOnly,
        ipAddress: '',
        batteryPercent: 62,
        respirationBpm: 15.8,
        lastSpokenPhrase: 'Family visiting today?',
        lastSeen: now.subtract(const Duration(minutes: 1)),
      ),
      MonitoredPatient(
        id: 'patient-bed-105',
        name: 'Fatima Al-Zahra',
        roomNumber: 'Bed 105 (Step-Down)',
        accessMethod: '3D Hand Gestures',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.105',
        batteryPercent: 98,
        respirationBpm: 18.1,
        lastSpokenPhrase: 'Thank you for lunch',
        lastSeen: now.subtract(const Duration(seconds: 1)),
      ),
      MonitoredPatient(
        id: 'patient-bed-106',
        name: 'David Kowalski',
        roomNumber: 'Bed 106 (Step-Down)',
        accessMethod: 'Head Motion Dynamics',
        connectionState: PatientConnectionState.disconnected,
        ipAddress: '',
        batteryPercent: 35,
        lastSeen: now.subtract(const Duration(minutes: 15)),
      ),
      MonitoredPatient(
        id: 'patient-bed-107',
        name: 'Amina Diallo',
        roomNumber: 'Bed 107 (Acute Ward)',
        accessMethod: '3D Hand Gestures',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.107',
        batteryPercent: 84,
        respirationBpm: 16.8,
        lastSpokenPhrase: 'Feeling comfortable',
        lastSeen: now.subtract(const Duration(seconds: 3)),
      ),
      MonitoredPatient(
        id: 'patient-bed-108',
        name: 'Robert Tanaka',
        roomNumber: 'Bed 108 (Acute Ward)',
        accessMethod: 'Face & Eye Gaze',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.108',
        batteryPercent: 91,
        respirationBpm: 20.4,
        lastSpokenPhrase: 'Can we dim the lights?',
        lastSeen: now.subtract(const Duration(seconds: 2)),
      ),
      MonitoredPatient(
        id: 'patient-bed-109',
        name: 'Helena Rodriguez',
        roomNumber: 'Bed 109 (Private Suite)',
        accessMethod: 'Face & Eye Gaze',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.109',
        batteryPercent: 73,
        respirationBpm: 17.5,
        lastSpokenPhrase: 'Call nurse when ready',
        lastSeen: now.subtract(const Duration(seconds: 1)),
      ),
      MonitoredPatient(
        id: 'patient-bed-110',
        name: 'Liam O\'Connor',
        roomNumber: 'Bed 110 (Private Suite)',
        accessMethod: 'Single-Switch Scan',
        connectionState: PatientConnectionState.cloudOnly,
        ipAddress: '',
        batteryPercent: 54,
        respirationBpm: 15.0,
        lastSpokenPhrase: 'Pain level 2 out of 10',
        lastSeen: now.subtract(const Duration(minutes: 3)),
      ),
      MonitoredPatient(
        id: 'patient-bed-111',
        name: 'Sunil Verma',
        roomNumber: 'Bed 111 (Home Care Unit)',
        accessMethod: '3D Hand Gestures',
        connectionState: PatientConnectionState.localLan,
        ipAddress: '192.168.1.111',
        batteryPercent: 89,
        respirationBpm: 16.0,
        lastSpokenPhrase: 'Ready for physiotherapy',
        lastSeen: now,
      ),
      MonitoredPatient(
        id: 'patient-bed-112',
        name: 'Grace Hopper',
        roomNumber: 'Bed 112 (Home Care Unit)',
        accessMethod: 'Face & Eye Gaze',
        connectionState: PatientConnectionState.disconnected,
        ipAddress: '',
        batteryPercent: 12,
        lastSeen: now.subtract(const Duration(hours: 1)),
      ),
    ]);
  }

  @override
  void dispose() {
    _beaconSub?.cancel();
    _healthCheckTimer?.cancel();
    super.dispose();
  }
}
