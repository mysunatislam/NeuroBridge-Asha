import 'package:fingerspeak_mobile/models/patient_record.dart';
import 'package:fingerspeak_mobile/models/patient_registry_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('PatientRegistryRepository & PatientRecord', () {
    test('seeds default patients on initial launch', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = PatientRegistryRepository(prefs);

      expect(repo.patients.length, equals(3));
      expect(repo.patients[0].id, equals('patient-01-rahim'));
      expect(repo.patients[0].name, contains('Rahim Chowdhury'));
      expect(repo.patients[1].id, equals('patient-02-sarah'));
      expect(repo.patients[1].name, contains('Sarah Jenkins'));
      expect(repo.patients[2].id, equals('patient-03-tariq'));
      expect(repo.patients[2].name, contains('Tariq Al-Mansoor'));

      expect(repo.activePatient.id, equals('patient-01-rahim'));
    });

    test('selectPatient switches active patient and notifies listeners', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = PatientRegistryRepository(prefs);

      var notified = false;
      repo.addListener(() => notified = true);

      await repo.selectPatient('patient-02-sarah');

      expect(repo.activePatientId, equals('patient-02-sarah'));
      expect(repo.activePatient.name, contains('Sarah Jenkins'));
      expect(notified, isTrue);
    });

    test('addPatient registers new individual patient record and persists', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = PatientRegistryRepository(prefs);

      final newPatient = PatientRecord(
        id: 'patient-04-elena',
        name: 'Elena Rostova',
        age: 44,
        condition: 'Traumatic Brain Injury',
        primaryModality: 'Lip Movement & Head Switch',
        roomNumber: 'ICU-4',
        doctorName: 'Dr. John Sterling',
        doctorPhone: '+1-555-0199',
        heartRate: 78,
        respirationRate: 18,
        painScore: 3,
        gestureAccuracy: 88,
        fatigueLevel: 'Moderate',
        currentActivity: 'Occupational therapy session in progress',
      );

      await repo.addPatient(newPatient);

      expect(repo.patients.length, equals(4));
      expect(repo.activePatientId, equals('patient-04-elena'));
      expect(repo.activePatient.name, equals('Elena Rostova'));

      // Verify persistence across new instance
      final repo2 = PatientRegistryRepository(prefs);
      expect(repo2.patients.length, equals(4));
      expect(repo2.patients.any((p) => p.id == 'patient-04-elena'), isTrue);
    });

    test('updatePatient modifies clinical attributes and physician directives', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = PatientRegistryRepository(prefs);

      final original = repo.activePatient;
      final updated = original.copyWith(
        age: 65,
        condition: 'Ischemic Stroke - Advanced Rehab',
        doctorDirectives: 'Advance to solid diet and unassisted head nod selection.',
      );

      await repo.updatePatient(updated);

      expect(repo.activePatient.age, equals(65));
      expect(repo.activePatient.condition, equals('Ischemic Stroke - Advanced Rehab'));
      expect(repo.activePatient.doctorDirectives, contains('Advance to solid diet'));
    });

    test('addFeedback logs clinical observation into patient timeline', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = PatientRegistryRepository(prefs);

      final initialCount = repo.activePatient.feedbackNotes.length;

      await repo.addFeedback(
        patientId: repo.activePatient.id,
        author: 'Dr. Anisur Rahman',
        category: 'Motor Recovery',
        notes: 'Significant improvement in index finger flexion velocity.',
      );

      expect(repo.activePatient.feedbackNotes.length, equals(initialCount + 1));
      final latest = repo.activePatient.feedbackNotes.first;
      expect(latest.author, equals('Dr. Anisur Rahman'));
      expect(latest.category, equals('Motor Recovery'));
      expect(latest.notes, contains('Significant improvement'));
    });

    test('sendMessageToPatient records message dispatch history', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = PatientRegistryRepository(prefs);

      final initialMsgCount = repo.activePatient.messagesSent.length;

      await repo.sendMessageToPatient(
        patientId: repo.activePatient.id,
        content: 'I am on my way with your lunch.',
        channel: 'Wheelchair Display + Asha Voice',
      );

      expect(repo.activePatient.messagesSent.length, equals(initialMsgCount + 1));
      final latest = repo.activePatient.messagesSent.first;
      expect(latest.content, equals('I am on my way with your lunch.'));
      expect(latest.channel, contains('Wheelchair Display'));
    });

    test('generateDoctorReport compiles complete clinical telemetry summary', () async {
      final prefs = await SharedPreferences.getInstance();
      final repo = PatientRegistryRepository(prefs);

      final report = await repo.generateDoctorReport(repo.activePatient.id);

      expect(report.id, isNotEmpty);
      expect(report.doctorName, equals(repo.activePatient.doctorName));
      expect(report.status, contains('Generated'));
      expect(report.summaryText, contains('CLINICAL PROGRESS & TELEMETRY REPORT'));
      expect(report.summaryText, contains(repo.activePatient.name));
      expect(report.summaryText, contains(repo.activePatient.condition));
      expect(report.summaryText, contains('BIOMETRIC & VITAL SIGNS:'));
      expect(report.summaryText, contains('${repo.activePatient.heartRate} bpm'));
      expect(report.summaryText, contains('${repo.activePatient.respirationRate} breaths/min'));
      expect(report.summaryText, contains('RECENT CAREGIVER OBSERVATIONS & FEEDBACK:'));
    });

    test('PatientRecord serializes and deserializes cleanly with copyWith', () {
      final record = PatientRecord(
        id: 'test-p1',
        name: 'Test Patient',
        age: 60,
        condition: 'ALS',
        primaryModality: 'Eye Gaze',
        roomNumber: 'Room 5',
        doctorName: 'Dr. Smith',
        doctorPhone: '555-1234',
        heartRate: 70,
        respirationRate: 14,
        painScore: 0,
        gestureAccuracy: 96,
        fatigueLevel: 'Low',
        currentActivity: 'Resting',
      );

      final json = record.toJson();
      final restored = PatientRecord.fromJson(json);

      expect(restored.id, equals(record.id));
      expect(restored.name, equals(record.name));
      expect(restored.age, equals(record.age));
      expect(restored.condition, equals(record.condition));
      expect(restored.primaryModality, equals(record.primaryModality));
      expect(restored.heartRate, equals(70));
    });
  });
}
