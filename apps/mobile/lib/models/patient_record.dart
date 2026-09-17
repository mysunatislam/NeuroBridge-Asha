
/// Individual patient feedback entry recorded by caregivers or clinicians.
class PatientFeedbackEntry {
  const PatientFeedbackEntry({
    required this.id,
    required this.timestamp,
    required this.author,
    required this.category,
    required this.notes,
  });

  factory PatientFeedbackEntry.fromJson(Map<String, dynamic> json) {
    return PatientFeedbackEntry(
      id: json['id'] as String? ?? 'fb-${DateTime.now().millisecondsSinceEpoch}',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      author: json['author'] as String? ?? 'Caregiver',
      category: json['category'] as String? ?? 'General',
      notes: json['notes'] as String? ?? '',
    );
  }

  final String id;
  final DateTime timestamp;
  final String author;
  final String category;
  final String notes;

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'author': author,
        'category': category,
        'notes': notes,
      };
}

/// Record of an outgoing message sent from caregiver to patient.
class CaregiverMessageEntry {
  const CaregiverMessageEntry({
    required this.id,
    required this.timestamp,
    required this.content,
    required this.channel,
    this.isDelivered = true,
  });

  factory CaregiverMessageEntry.fromJson(Map<String, dynamic> json) {
    return CaregiverMessageEntry(
      id: json['id'] as String? ?? 'msg-${DateTime.now().millisecondsSinceEpoch}',
      timestamp: json['timestamp'] != null
          ? DateTime.tryParse(json['timestamp'] as String) ?? DateTime.now()
          : DateTime.now(),
      content: json['content'] as String? ?? '',
      channel: json['channel'] as String? ?? 'Wheelchair Display',
      isDelivered: json['is_delivered'] as bool? ?? true,
    );
  }

  final String id;
  final DateTime timestamp;
  final String content;
  final String channel;
  final bool isDelivered;

  Map<String, dynamic> toJson() => {
        'id': id,
        'timestamp': timestamp.toIso8601String(),
        'content': content,
        'channel': channel,
        'is_delivered': isDelivered,
      };
}

/// Clinical Doctor Report generated for a patient.
class DoctorReportSummary {
  const DoctorReportSummary({
    required this.id,
    required this.generatedAt,
    required this.summaryText,
    required this.doctorName,
    this.status = 'Generated',
  });

  factory DoctorReportSummary.fromJson(Map<String, dynamic> json) {
    return DoctorReportSummary(
      id: json['id'] as String? ?? 'rep-${DateTime.now().millisecondsSinceEpoch}',
      generatedAt: json['generated_at'] != null
          ? DateTime.tryParse(json['generated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      summaryText: json['summary_text'] as String? ?? '',
      doctorName: json['doctor_name'] as String? ?? '',
      status: json['status'] as String? ?? 'Generated',
    );
  }

  final String id;
  final DateTime generatedAt;
  final String summaryText;
  final String doctorName;
  final String status;

  Map<String, dynamic> toJson() => {
        'id': id,
        'generated_at': generatedAt.toIso8601String(),
        'summary_text': summaryText,
        'doctor_name': doctorName,
        'status': status,
      };
}

/// Comprehensive patient model with personalized clinical, vital, and tele-monitoring data.
class PatientRecord {
  PatientRecord({
    required this.id,
    required this.name,
    required this.age,
    required this.condition,
    required this.primaryModality,
    this.roomNumber = 'Ward 3B - Bed 12',
    this.doctorName = 'Dr. Anisur Rahman',
    this.doctorPhone = '+8801711000001',
    this.doctorHospital = 'National Institute of Neurosciences',
    this.doctorEmail = 'dr.rahman@neurobridge.org',
    this.doctorDirectives = 'Post-stroke motor relearning 2x daily. Monitor spasticity and hydration.',
    this.heartRate = 74,
    this.respirationRate = 16,
    this.painScore = 1,
    this.gestureAccuracy = 94,
    this.fatigueLevel = 'Low',
    this.currentActivity = 'Resting comfortably in wheelchair',
    this.cameraLiveAvailable = true,
    this.isCameraStreaming = false,
    List<PatientFeedbackEntry>? feedbackNotes,
    List<CaregiverMessageEntry>? messagesSent,
    List<DoctorReportSummary>? doctorReports,
  })  : feedbackNotes = feedbackNotes ?? [],
        messagesSent = messagesSent ?? [],
        doctorReports = doctorReports ?? [];

  factory PatientRecord.fromJson(Map<String, dynamic> json) {
    return PatientRecord(
      id: json['id'] as String? ?? 'patient-${DateTime.now().millisecondsSinceEpoch}',
      name: json['name'] as String? ?? 'Unnamed Patient',
      age: json['age'] as int? ?? 60,
      condition: json['condition'] as String? ?? 'Neurological condition',
      primaryModality: json['primary_modality'] as String? ?? 'Hand Gestures',
      roomNumber: json['room_number'] as String? ?? 'Ward 3B',
      doctorName: json['doctor_name'] as String? ?? 'Dr. Anisur Rahman',
      doctorPhone: json['doctor_phone'] as String? ?? '+8801711000001',
      doctorHospital: json['doctor_hospital'] as String? ?? 'Neuro Hospital',
      doctorEmail: json['doctor_email'] as String? ?? 'doctor@neurobridge.org',
      doctorDirectives: json['doctor_directives'] as String? ?? 'Standard monitoring.',
      heartRate: json['heart_rate'] as int? ?? 72,
      respirationRate: json['respiration_rate'] as int? ?? 16,
      painScore: json['pain_score'] as int? ?? 1,
      gestureAccuracy: json['gesture_accuracy'] as int? ?? 92,
      fatigueLevel: json['fatigue_level'] as String? ?? 'Low',
      currentActivity: json['current_activity'] as String? ?? 'Resting',
      cameraLiveAvailable: json['camera_live_available'] as bool? ?? true,
      isCameraStreaming: json['is_camera_streaming'] as bool? ?? false,
      feedbackNotes: (json['feedback_notes'] as List<dynamic>? ?? [])
          .map((e) => PatientFeedbackEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      messagesSent: (json['messages_sent'] as List<dynamic>? ?? [])
          .map((e) => CaregiverMessageEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      doctorReports: (json['doctor_reports'] as List<dynamic>? ?? [])
          .map((e) => DoctorReportSummary.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  final String id;
  String name;
  int age;
  String condition;
  String primaryModality;
  String roomNumber;
  String doctorName;
  String doctorPhone;
  String doctorHospital;
  String doctorEmail;
  String doctorDirectives;
  int heartRate;
  int respirationRate;
  int painScore;
  int gestureAccuracy;
  String fatigueLevel;
  String currentActivity;
  bool cameraLiveAvailable;
  bool isCameraStreaming;
  final List<PatientFeedbackEntry> feedbackNotes;
  final List<CaregiverMessageEntry> messagesSent;
  final List<DoctorReportSummary> doctorReports;

  PatientRecord copyWith({
    String? id,
    String? name,
    int? age,
    String? condition,
    String? primaryModality,
    String? roomNumber,
    String? doctorName,
    String? doctorPhone,
    String? doctorHospital,
    String? doctorEmail,
    String? doctorDirectives,
    int? heartRate,
    int? respirationRate,
    int? painScore,
    int? gestureAccuracy,
    String? fatigueLevel,
    String? currentActivity,
    bool? cameraLiveAvailable,
    bool? isCameraStreaming,
    List<PatientFeedbackEntry>? feedbackNotes,
    List<CaregiverMessageEntry>? messagesSent,
    List<DoctorReportSummary>? doctorReports,
  }) {
    return PatientRecord(
      id: id ?? this.id,
      name: name ?? this.name,
      age: age ?? this.age,
      condition: condition ?? this.condition,
      primaryModality: primaryModality ?? this.primaryModality,
      roomNumber: roomNumber ?? this.roomNumber,
      doctorName: doctorName ?? this.doctorName,
      doctorPhone: doctorPhone ?? this.doctorPhone,
      doctorHospital: doctorHospital ?? this.doctorHospital,
      doctorEmail: doctorEmail ?? this.doctorEmail,
      doctorDirectives: doctorDirectives ?? this.doctorDirectives,
      heartRate: heartRate ?? this.heartRate,
      respirationRate: respirationRate ?? this.respirationRate,
      painScore: painScore ?? this.painScore,
      gestureAccuracy: gestureAccuracy ?? this.gestureAccuracy,
      fatigueLevel: fatigueLevel ?? this.fatigueLevel,
      currentActivity: currentActivity ?? this.currentActivity,
      cameraLiveAvailable: cameraLiveAvailable ?? this.cameraLiveAvailable,
      isCameraStreaming: isCameraStreaming ?? this.isCameraStreaming,
      feedbackNotes: feedbackNotes ?? List.from(this.feedbackNotes),
      messagesSent: messagesSent ?? List.from(this.messagesSent),
      doctorReports: doctorReports ?? List.from(this.doctorReports),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'age': age,
        'condition': condition,
        'primary_modality': primaryModality,
        'room_number': roomNumber,
        'doctor_name': doctorName,
        'doctor_phone': doctorPhone,
        'doctor_hospital': doctorHospital,
        'doctor_email': doctorEmail,
        'doctor_directives': doctorDirectives,
        'heart_rate': heartRate,
        'respiration_rate': respirationRate,
        'pain_score': painScore,
        'gesture_accuracy': gestureAccuracy,
        'fatigue_level': fatigueLevel,
        'current_activity': currentActivity,
        'camera_live_available': cameraLiveAvailable,
        'is_camera_streaming': isCameraStreaming,
        'feedback_notes': feedbackNotes.map((e) => e.toJson()).toList(),
        'messages_sent': messagesSent.map((e) => e.toJson()).toList(),
        'doctor_reports': doctorReports.map((e) => e.toJson()).toList(),
      };
}
