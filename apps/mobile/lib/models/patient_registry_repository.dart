import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'patient_record.dart';

class PatientRegistryRepository extends ChangeNotifier {
  PatientRegistryRepository(this._preferences) {
    _load();
  }

  final SharedPreferences _preferences;
  static const _kPatientsStorageKey = 'neurobridge_patient_registry_v1';
  static const _kActivePatientStorageKey = 'neurobridge_active_patient_id_v1';

  final List<PatientRecord> _patients = [];
  String? _activePatientId;

  List<PatientRecord> get patients => List.unmodifiable(_patients);
  String? get activePatientId => _activePatientId;

  PatientRecord get activePatient {
    if (_patients.isEmpty) {
      _seedDefaults();
    }
    return _patients.firstWhere(
      (p) => p.id == _activePatientId,
      orElse: () => _patients.first,
    );
  }

  void _load() {
    final raw = _preferences.getString(_kPatientsStorageKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw) as List<dynamic>;
        _patients.clear();
        for (final item in decoded) {
          _patients.add(PatientRecord.fromJson(item as Map<String, dynamic>));
        }
      } catch (e) {
        debugPrint('Failed to load patient registry: $e');
        _seedDefaults();
      }
    }

    if (_patients.isEmpty) {
      _seedDefaults();
    }

    _activePatientId = _preferences.getString(_kActivePatientStorageKey) ?? _patients.first.id;
  }

  void _seedDefaults() {
    _patients.clear();
    _patients.addAll([
      PatientRecord(
        id: 'patient-01-rahim',
        name: 'Rahim Chowdhury',
        age: 64,
        condition: 'Ischemic Stroke (Right Hemiparesis)',
        primaryModality: 'Right Hand Micro-gestures & Eye Blink',
        roomNumber: 'Ward 3B - Bed 12',
        doctorName: 'Dr. Anisur Rahman, Neurologist',
        doctorPhone: '+8801711000001',
        doctorHospital: 'National Institute of Neurosciences & Hospital',
        doctorEmail: 'dr.rahman@nins.gov.bd',
        doctorDirectives: 'Post-stroke bilateral mirror exercises 2x daily. Monitor carotid circulation and safe hydration with level 2 thickener.',
        heartRate: 74,
        respirationRate: 16,
        painScore: 2,
        gestureAccuracy: 95,
        fatigueLevel: 'Low',
        currentActivity: 'Resting comfortably in wheelchair (Communicating in Bangla)',
        cameraLiveAvailable: true,
        isCameraStreaming: false,
        feedbackNotes: [
          PatientFeedbackEntry(
            id: 'fb-01',
            timestamp: DateTime.now().subtract(const Duration(hours: 3)),
            author: 'Nurse Fatima',
            category: 'Mobility',
            notes: 'Completed 12 right-hand finger extension taps with high dwell stability.',
          ),
          PatientFeedbackEntry(
            id: 'fb-02',
            timestamp: DateTime.now().subtract(const Duration(hours: 1)),
            author: 'Caregiver Aysha',
            category: 'Hydration',
            notes: 'Drank 200ml water safely in upright 90-degree sitting posture.',
          ),
        ],
        messagesSent: [
          CaregiverMessageEntry(
            id: 'msg-01',
            timestamp: DateTime.now().subtract(const Duration(hours: 2)),
            content: 'I am on my way with your lunch.',
            channel: 'Wheelchair Display',
          ),
        ],
      ),
      PatientRecord(
        id: 'patient-02-sarah',
        name: 'Sarah Jenkins',
        age: 52,
        condition: 'Bulbar ALS / Motor Neuron Disease',
        primaryModality: 'Eye Gaze & Blink Scanning',
        roomNumber: 'Home Care - Room 1',
        doctorName: 'Dr. Clara Vance, MND Specialist',
        doctorPhone: '+1-555-019-2834',
        doctorHospital: 'Metropolitan Neuro-Care Center',
        doctorEmail: 'dr.vance@neurocare.org',
        doctorDirectives: 'Maintain 650ms dwell time to avoid motor fatigue. Use Passy-Muir speaking valve protocol and frequent low-effort resting states.',
        heartRate: 80,
        respirationRate: 18,
        painScore: 1,
        gestureAccuracy: 91,
        fatigueLevel: 'Moderate',
        currentActivity: 'Resting on supportive recliner armrest',
        cameraLiveAvailable: true,
        isCameraStreaming: false,
        feedbackNotes: [
          PatientFeedbackEntry(
            id: 'fb-03',
            timestamp: DateTime.now().subtract(const Duration(hours: 5)),
            author: 'Caregiver Michael',
            category: 'Energy Conservation',
            notes: 'Patient showed early signs of thumb fatigue; transitioned access grid to eye-blink scanning.',
          ),
        ],
        messagesSent: [
          CaregiverMessageEntry(
            id: 'msg-02',
            timestamp: DateTime.now().subtract(const Duration(hours: 4)),
            content: 'Take your time and rest well.',
            channel: 'TTS Spoken',
          ),
        ],
      ),
      PatientRecord(
        id: 'patient-03-tariq',
        name: 'Tariq Al-Mansoor',
        age: 38,
        condition: 'Spinal Cord Injury (T6 Complete, Dysreflexia Risk)',
        primaryModality: 'Head Pose & Single-Switch',
        roomNumber: 'Rehab Wing - Bed 04',
        doctorName: 'Dr. Marcus Brody, Physiatrist',
        doctorPhone: '+1-555-014-9988',
        doctorHospital: 'Spinal Mobility Rehabilitation Institute',
        doctorEmail: 'm.brody@spinalrehab.org',
        doctorDirectives: 'Strict 2-hour pressure relief schedule. Check Foley catheter immediately if pounding headache or facial flushing occurs.',
        heartRate: 68,
        respirationRate: 15,
        painScore: 3,
        gestureAccuracy: 98,
        fatigueLevel: 'Low',
        currentActivity: 'Wheelchair upright sitting, monitoring catheter flow',
        cameraLiveAvailable: true,
        isCameraStreaming: false,
        feedbackNotes: [
          PatientFeedbackEntry(
            id: 'fb-04',
            timestamp: DateTime.now().subtract(const Duration(minutes: 45)),
            author: 'Physiotherapist David',
            category: 'Positioning',
            notes: 'Wheelchair tilt repositioning completed. Skin over sacrum checked intact without erythema.',
          ),
        ],
        messagesSent: [],
      ),
    ]);
    _activePatientId = _patients.first.id;
  }

  Future<void> _persist() async {
    final raw = jsonEncode(_patients.map((p) => p.toJson()).toList());
    await _preferences.setString(_kPatientsStorageKey, raw);
    if (_activePatientId != null) {
      await _preferences.setString(_kActivePatientStorageKey, _activePatientId!);
    }
    notifyListeners();
  }

  Future<void> selectPatient(String patientId) async {
    final exists = _patients.any((p) => p.id == patientId);
    if (exists) {
      _activePatientId = patientId;
      await _preferences.setString(_kActivePatientStorageKey, patientId);
      notifyListeners();
    }
  }

  Future<void> addPatient(PatientRecord record) async {
    _patients.add(record);
    _activePatientId = record.id;
    await _persist();
  }

  Future<void> updatePatient(PatientRecord updated) async {
    final idx = _patients.indexWhere((p) => p.id == updated.id);
    if (idx != -1) {
      _patients[idx] = updated;
      await _persist();
    }
  }

  Future<void> deletePatient(String patientId) async {
    if (_patients.length <= 1) return; // Keep at least one patient
    _patients.removeWhere((p) => p.id == patientId);
    if (_activePatientId == patientId) {
      _activePatientId = _patients.first.id;
    }
    await _persist();
  }

  Future<void> addFeedback({
    required String patientId,
    required String author,
    required String category,
    required String notes,
  }) async {
    final idx = _patients.indexWhere((p) => p.id == patientId);
    if (idx != -1) {
      final entry = PatientFeedbackEntry(
        id: 'fb-${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        author: author,
        category: category,
        notes: notes,
      );
      _patients[idx].feedbackNotes.insert(0, entry);
      await _persist();
    }
  }

  Future<void> sendMessageToPatient({
    required String patientId,
    required String content,
    required String channel,
  }) async {
    final idx = _patients.indexWhere((p) => p.id == patientId);
    if (idx != -1) {
      final entry = CaregiverMessageEntry(
        id: 'msg-${DateTime.now().millisecondsSinceEpoch}',
        timestamp: DateTime.now(),
        content: content,
        channel: channel,
      );
      _patients[idx].messagesSent.insert(0, entry);
      await _persist();
    }
  }

  Future<DoctorReportSummary> generateDoctorReport(String patientId) async {
    final idx = _patients.indexWhere((p) => p.id == patientId);
    if (idx == -1) {
      throw ArgumentError('Patient not found');
    }
    final patient = _patients[idx];
    final now = DateTime.now();

    final buffer = StringBuffer();
    buffer.writeln('CLINICAL PROGRESS & TELEMETRY REPORT');
    buffer.writeln('====================================');
    buffer.writeln('Patient: ${patient.name} (Age: ${patient.age})');
    buffer.writeln('Location: ${patient.roomNumber}');
    buffer.writeln('Clinical Condition: ${patient.condition}');
    buffer.writeln('Primary Input Modality: ${patient.primaryModality}');
    buffer.writeln('Attending Physician: ${patient.doctorName} (${patient.doctorHospital})');
    buffer.writeln('Physician Contact: ${patient.doctorPhone} | ${patient.doctorEmail}');
    buffer.writeln('Physician Care Directives: ${patient.doctorDirectives}');
    buffer.writeln('');
    buffer.writeln('BIOMETRIC & VITAL SIGNS:');
    buffer.writeln('• Resting Heart Rate: ${patient.heartRate} bpm');
    buffer.writeln('• Respiration Rate: ${patient.respirationRate} breaths/min');
    buffer.writeln('• PAINAD / Visual Pain Score: ${patient.painScore} / 10');
    buffer.writeln('• Gesture Recognition Accuracy: ${patient.gestureAccuracy}%');
    buffer.writeln('• Motor Fatigue Level: ${patient.fatigueLevel}');
    buffer.writeln('• Current Activity State: ${patient.currentActivity}');
    buffer.writeln('');
    buffer.writeln('RECENT CAREGIVER OBSERVATIONS & FEEDBACK:');
    if (patient.feedbackNotes.isEmpty) {
      buffer.writeln('• No clinical feedback logged today.');
    } else {
      for (final fb in patient.feedbackNotes.take(5)) {
        buffer.writeln('• [${fb.category}] (${fb.author}): ${fb.notes}');
      }
    }
    buffer.writeln('');
    buffer.writeln('COMMUNICATION ENGAGEMENT:');
    buffer.writeln('• Caregiver Messages Delivered: ${patient.messagesSent.length}');
    buffer.writeln('• Report Generated At: ${now.toIso8601String()}');
    buffer.writeln('NeuroBridge Asha Assistive Intelligence Platform (v3.0.0)');

    final report = DoctorReportSummary(
      id: 'rep-${now.millisecondsSinceEpoch}',
      generatedAt: now,
      summaryText: buffer.toString(),
      doctorName: patient.doctorName,
      status: 'Generated & Signed',
    );

    patient.doctorReports.insert(0, report);
    await _persist();
    return report;
  }
}
