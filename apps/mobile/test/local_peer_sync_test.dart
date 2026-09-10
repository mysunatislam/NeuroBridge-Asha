import 'package:fingerspeak_mobile/services/local_peer_sync_service.dart';
import 'package:fingerspeak_mobile/services/patient_roster_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AshaPatientBeacon', () {
    test('serializes and deserializes correctly', () {
      final now = DateTime.now();
      final beacon = AshaPatientBeacon(
        patientId: 'patient-test-1',
        name: 'Eleanor Vance',
        roomNumber: 'Bed 101',
        status: 'active',
        batteryPercent: 92,
        accessMethod: '3D Hand Gestures',
        ipAddress: '192.168.1.50',
        httpPort: 41529,
        timestamp: now,
        respirationBpm: 16.5,
        lastSpokenPhrase: 'I need water',
        isEmergency: false,
      );

      final json = beacon.toJson();
      expect(json['patientId'], 'patient-test-1');
      expect(json['batteryPercent'], 92);
      expect(json['isEmergency'], false);

      final restored = AshaPatientBeacon.fromJson(json);
      expect(restored.patientId, beacon.patientId);
      expect(restored.name, beacon.name);
      expect(restored.roomNumber, beacon.roomNumber);
      expect(restored.batteryPercent, beacon.batteryPercent);
      expect(restored.respirationBpm, beacon.respirationBpm);
      expect(restored.lastSpokenPhrase, beacon.lastSpokenPhrase);
    });

    test('handles fallback defaults gracefully when fields are missing', () {
      final beacon = AshaPatientBeacon.fromJson({});
      expect(beacon.patientId, 'unknown-patient');
      expect(beacon.name, 'Patient');
      expect(beacon.batteryPercent, 100);
      expect(beacon.isEmergency, false);
    });
  });

  group('PatientRosterService', () {
    late SharedPreferences prefs;
    late LocalPeerSyncService peerSync;
    late PatientRosterService roster;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
      peerSync = LocalPeerSyncService();
      roster = PatientRosterService(preferences: prefs, peerSync: peerSync);
    });

    tearDown(() {
      roster.dispose();
      peerSync.dispose();
    });

    test('pre-seeds clinical ward patients on first launch', () {
      expect(roster.patients.length, greaterThanOrEqualTo(10));
      final bed101 = roster.patients.firstWhere((p) => p.id == 'patient-bed-101');
      expect(bed101.name, 'Eleanor Vance');
      expect(bed101.connectionState, PatientConnectionState.localLan);
    });

    test('emergency sorting prioritizes patients in distress at index 0', () async {
      final patient = roster.patients.last;
      patient.isEmergency = true;
      await roster.addPatient(MonitoredPatient(
        id: 'patient-sos-999',
        name: 'Urgent Patient',
        roomNumber: 'Bed 999',
        accessMethod: 'Face & Eyes',
        lastSeen: DateTime.now(),
        isEmergency: true,
      ));

      expect(roster.emergencyCount, greaterThanOrEqualTo(1));
      expect(roster.patients.first.isEmergency, true);
    });

    test('acknowledging emergency resets emergency flag', () async {
      await roster.addPatient(MonitoredPatient(
        id: 'patient-test-ack',
        name: 'Test Ack',
        roomNumber: 'Bed 200',
        accessMethod: 'Hand Gestures',
        lastSeen: DateTime.now(),
        isEmergency: true,
      ));

      expect(roster.emergencyCount, greaterThanOrEqualTo(1));
      await roster.acknowledgeEmergency('patient-test-ack');

      final patient = roster.patients.firstWhere((p) => p.id == 'patient-test-ack');
      expect(patient.isEmergency, false);
    });
  });
}
