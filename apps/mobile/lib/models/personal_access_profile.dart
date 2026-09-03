// personal_access_profile.dart
// NeuroBridge Personalized Access Intelligence Profile.
// Encapsulates physical interaction capabilities, digital capability scores,
// primary + backup input modalities, safety thresholds, and language preferences.

enum BodyPart {
  rightHand('Right hand / fingers'),
  leftHand('Left hand / fingers'),
  wrist('Wrist mobility'),
  head('Head movement'),
  facialMuscles('Facial muscles & expressions'),
  eyes('Eyes & gaze fixation'),
  blink('Voluntary blink'),
  voice('Speech & vocal sounds'),
  touchScreen('Touchscreen tapping'),
  singleSwitch('Single voluntary movement');

  const BodyPart(this.label);
  final String label;
}

enum CapabilityGrade {
  unavailable('Unavailable', 0.0),
  limited('Limited / Weak', 0.25),
  moderate('Moderate / Partial', 0.55),
  good('Good / Reliable', 0.80),
  excellent('Excellent / Strong', 1.0);

  const CapabilityGrade(this.label, this.scoreWeight);
  final String label;
  final double scoreWeight;
}

enum AccessModality {
  handGestures('Hand & Finger Gestures', 'Uses MediaPipe 3D hand tracking'),
  facialControls('Facial Expressions', 'Eyebrow raise, smile, mouth movements'),
  eyeBlinkGaze('Eye Gaze & Blink', 'Fixation dwell, long blink, double blink'),
  headMovement('Head Pose & Tilt', 'Nod, head turn, tilt tracking'),
  singleSwitchScanning('Single-Movement Scanning', 'Auto-scanning with single trigger confirmation'),
  touchScreen('Direct Touch UI', 'High-contrast accessible on-screen buttons'),
  voiceCommands('Voice & Sound Control', 'Vocal phrase and acoustic triggers');

  const AccessModality(this.title, this.description);
  final String title;
  final String description;
}

enum SensitivityLevel {
  low('Low sensitivity (Tolerates tremor)', 0.85, 900),
  medium('Standard sensitivity', 0.75, 650),
  high('High sensitivity (Light movements)', 0.60, 450);

  const SensitivityLevel(this.label, this.threshold, this.defaultDwellMs);
  final String label;
  final double threshold;
  final int defaultDwellMs;
}

enum AppLanguage {
  english('English', 'en'),
  bangla('বাংলা (Bangla)', 'bn'),
  bilingual('Bilingual (English + বাংলা)', 'mixed');

  const AppLanguage(this.label, this.code);
  final String label;
  final String code;
}

class PersonalAccessProfile {
  PersonalAccessProfile({
    required this.id,
    required this.patientName,
    required this.capabilities,
    required this.primaryModality,
    this.backupModality,
    this.sensitivity = SensitivityLevel.medium,
    this.dwellTimeMs = 650,
    this.lockoutDurationMs = 1200,
    this.tremorToleranceEnabled = true,
    this.tremorFilterAlpha = 0.4,
    this.language = AppLanguage.english,
    this.caregiverAssistedSetup = false,
    this.patientAge,
    this.conditionNotes,
    this.caregiverName,
    this.caregiverContact,
    DateTime? createdAt,
    DateTime? lastCalibratedAt,
    this.customVocabulary = const {},
  })  : createdAt = createdAt ?? DateTime.now(),
        lastCalibratedAt = lastCalibratedAt ?? DateTime.now();

  final String id;
  final String patientName;
  final int? patientAge;
  final String? conditionNotes;
  final String? caregiverName;
  final String? caregiverContact;
  final Map<BodyPart, CapabilityGrade> capabilities;
  final AccessModality primaryModality;
  final AccessModality? backupModality;
  final SensitivityLevel sensitivity;
  final int dwellTimeMs;
  final int lockoutDurationMs;
  final bool tremorToleranceEnabled;
  final double tremorFilterAlpha;
  final AppLanguage language;
  final bool caregiverAssistedSetup;
  final DateTime createdAt;
  final DateTime lastCalibratedAt;
  final Map<String, String> customVocabulary;

  /// Calculates Interaction Capability Scores (0 to 100%) for distinct body regions.
  Map<String, int> get capabilityScores {
    int scoreOf(BodyPart part) =>
        ((capabilities[part] ?? CapabilityGrade.unavailable).scoreWeight * 100)
            .round();

    return {
      'Right Hand': scoreOf(BodyPart.rightHand),
      'Left Hand': scoreOf(BodyPart.leftHand),
      'Head Control': scoreOf(BodyPart.head),
      'Eye / Blink Control': ((scoreOf(BodyPart.eyes) * 0.5) +
              (scoreOf(BodyPart.blink) * 0.5))
          .round(),
      'Facial Control': scoreOf(BodyPart.facialMuscles),
      'Speech': scoreOf(BodyPart.voice),
      'Touch Capability': scoreOf(BodyPart.touchScreen),
    };
  }

  /// Default fallback profile for initial setup.
  factory PersonalAccessProfile.defaultProfile({String name = 'Patient'}) {
    return PersonalAccessProfile(
      id: 'profile_',
      patientName: name,
      capabilities: {
        BodyPart.rightHand: CapabilityGrade.good,
        BodyPart.leftHand: CapabilityGrade.limited,
        BodyPart.wrist: CapabilityGrade.moderate,
        BodyPart.head: CapabilityGrade.good,
        BodyPart.facialMuscles: CapabilityGrade.good,
        BodyPart.eyes: CapabilityGrade.good,
        BodyPart.blink: CapabilityGrade.excellent,
        BodyPart.voice: CapabilityGrade.unavailable,
        BodyPart.touchScreen: CapabilityGrade.limited,
        BodyPart.singleSwitch: CapabilityGrade.good,
      },
      primaryModality: AccessModality.handGestures,
      backupModality: AccessModality.eyeBlinkGaze,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'patientName': patientName,
      'patientAge': patientAge,
      'conditionNotes': conditionNotes,
      'caregiverName': caregiverName,
      'caregiverContact': caregiverContact,
      'capabilities': capabilities.map(
        (key, value) => MapEntry(key.name, value.name),
      ),
      'primaryModality': primaryModality.name,
      'backupModality': backupModality?.name,
      'sensitivity': sensitivity.name,
      'dwellTimeMs': dwellTimeMs,
      'lockoutDurationMs': lockoutDurationMs,
      'tremorToleranceEnabled': tremorToleranceEnabled,
      'tremorFilterAlpha': tremorFilterAlpha,
      'language': language.name,
      'caregiverAssistedSetup': caregiverAssistedSetup,
      'createdAt': createdAt.toIso8601String(),
      'lastCalibratedAt': lastCalibratedAt.toIso8601String(),
      'customVocabulary': customVocabulary,
    };
  }

  factory PersonalAccessProfile.fromJson(Map<String, dynamic> json) {
    final rawCaps = json['capabilities'] as Map<String, dynamic>? ?? {};
    final capabilities = <BodyPart, CapabilityGrade>{};
    for (final entry in rawCaps.entries) {
      final part = BodyPart.values.cast<BodyPart?>().firstWhere(
            (p) => p?.name == entry.key,
            orElse: () => null,
          );
      final grade = CapabilityGrade.values.cast<CapabilityGrade?>().firstWhere(
            (g) => g?.name == entry.value,
            orElse: () => null,
          );
      if (part != null && grade != null) {
        capabilities[part] = grade;
      }
    }

    final primary = AccessModality.values.firstWhere(
      (m) => m.name == json['primaryModality'],
      orElse: () => AccessModality.handGestures,
    );

    final backup = json['backupModality'] != null
        ? AccessModality.values.cast<AccessModality?>().firstWhere(
              (m) => m?.name == json['backupModality'],
              orElse: () => null,
            )
        : null;

    final sens = SensitivityLevel.values.firstWhere(
      (s) => s.name == json['sensitivity'],
      orElse: () => SensitivityLevel.medium,
    );

    final lang = AppLanguage.values.firstWhere(
      (l) => l.name == json['language'],
      orElse: () => AppLanguage.english,
    );

    return PersonalAccessProfile(
      id: json['id'] as String? ?? 'profile_default',
      patientName: json['patientName'] as String? ?? 'Patient',
      patientAge: json['patientAge'] as int?,
      conditionNotes: json['conditionNotes'] as String?,
      caregiverName: json['caregiverName'] as String?,
      caregiverContact: json['caregiverContact'] as String?,
      capabilities: capabilities,
      primaryModality: primary,
      backupModality: backup,
      sensitivity: sens,
      dwellTimeMs: json['dwellTimeMs'] as int? ?? 650,
      lockoutDurationMs: json['lockoutDurationMs'] as int? ?? 1200,
      tremorToleranceEnabled:
          json['tremorToleranceEnabled'] as bool? ?? true,
      tremorFilterAlpha:
          (json['tremorFilterAlpha'] as num?)?.toDouble() ?? 0.4,
      language: lang,
      caregiverAssistedSetup:
          json['caregiverAssistedSetup'] as bool? ?? false,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
      lastCalibratedAt: json['lastCalibratedAt'] != null
          ? DateTime.tryParse(json['lastCalibratedAt'] as String) ??
              DateTime.now()
          : DateTime.now(),
      customVocabulary:
          (json['customVocabulary'] as Map<String, dynamic>?)?.map(
                (k, v) => MapEntry(k, v.toString()),
              ) ??
              const {},
    );
  }

  PersonalAccessProfile copyWith({
    String? patientName,
    int? patientAge,
    String? conditionNotes,
    String? caregiverName,
    String? caregiverContact,
    Map<BodyPart, CapabilityGrade>? capabilities,
    AccessModality? primaryModality,
    AccessModality? backupModality,
    SensitivityLevel? sensitivity,
    int? dwellTimeMs,
    int? lockoutDurationMs,
    bool? tremorToleranceEnabled,
    double? tremorFilterAlpha,
    AppLanguage? language,
    bool? caregiverAssistedSetup,
    DateTime? lastCalibratedAt,
    Map<String, String>? customVocabulary,
  }) {
    return PersonalAccessProfile(
      id: id,
      patientName: patientName ?? this.patientName,
      patientAge: patientAge ?? this.patientAge,
      conditionNotes: conditionNotes ?? this.conditionNotes,
      caregiverName: caregiverName ?? this.caregiverName,
      caregiverContact: caregiverContact ?? this.caregiverContact,
      capabilities: capabilities ?? this.capabilities,
      primaryModality: primaryModality ?? this.primaryModality,
      backupModality: backupModality ?? this.backupModality,
      sensitivity: sensitivity ?? this.sensitivity,
      dwellTimeMs: dwellTimeMs ?? this.dwellTimeMs,
      lockoutDurationMs: lockoutDurationMs ?? this.lockoutDurationMs,
      tremorToleranceEnabled:
          tremorToleranceEnabled ?? this.tremorToleranceEnabled,
      tremorFilterAlpha: tremorFilterAlpha ?? this.tremorFilterAlpha,
      language: language ?? this.language,
      caregiverAssistedSetup:
          caregiverAssistedSetup ?? this.caregiverAssistedSetup,
      createdAt: createdAt,
      lastCalibratedAt: lastCalibratedAt ?? this.lastCalibratedAt,
      customVocabulary: customVocabulary ?? this.customVocabulary,
    );
  }
}
