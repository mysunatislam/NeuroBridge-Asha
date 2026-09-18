import 'dart:async';
import 'dart:convert';

import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NeutralFaceBaseline {
  const NeutralFaceBaseline({
    required this.eyebrowDistance,
    required this.mouthDistance,
    required this.leftEyeOpenness,
    required this.rightEyeOpenness,
    this.smileProbability = 0.05,
    this.headYaw = 0,
    this.headPitch = 0,
  });

  static const standard = NeutralFaceBaseline(
    eyebrowDistance: 0.18,
    mouthDistance: 0.08,
    leftEyeOpenness: 0.85,
    rightEyeOpenness: 0.85,
    smileProbability: 0.05,
    headYaw: 0,
    headPitch: 0,
  );

  final double eyebrowDistance;
  final double mouthDistance;
  final double leftEyeOpenness;
  final double rightEyeOpenness;
  final double smileProbability;
  final double headYaw;
  final double headPitch;

  Map<String, Object> toJson() => {
        'eyebrow_distance': eyebrowDistance,
        'mouth_distance': mouthDistance,
        'left_eye_openness': leftEyeOpenness,
        'right_eye_openness': rightEyeOpenness,
        'smile_probability': smileProbability,
        'head_yaw': headYaw,
        'head_pitch': headPitch,
      };

  factory NeutralFaceBaseline.fromJson(Map<String, Object?> json) {
    double value(String key,
        {required double minimum, required double maximum}) {
      final raw = json[key];
      if (raw is! num || !raw.isFinite) {
        throw FormatException('Invalid neutral baseline value: $key');
      }
      final parsed = raw.toDouble();
      if (parsed < minimum || parsed > maximum) {
        throw FormatException('Neutral baseline value out of range: $key');
      }
      return parsed;
    }

    double optionalValue(
      String key,
      double fallback, {
      required double minimum,
      required double maximum,
    }) {
      if (!json.containsKey(key)) return fallback;
      return value(key, minimum: minimum, maximum: maximum);
    }

    return NeutralFaceBaseline(
      eyebrowDistance: value('eyebrow_distance', minimum: 0.01, maximum: 0.50),
      mouthDistance: value('mouth_distance', minimum: 0, maximum: 0.50),
      leftEyeOpenness: value('left_eye_openness', minimum: 0.05, maximum: 1),
      rightEyeOpenness: value('right_eye_openness', minimum: 0.05, maximum: 1),
      smileProbability: optionalValue(
        'smile_probability',
        0.05,
        minimum: 0,
        maximum: 1,
      ),
      headYaw: optionalValue(
        'head_yaw',
        0,
        minimum: -60,
        maximum: 60,
      ),
      headPitch: optionalValue(
        'head_pitch',
        0,
        minimum: -60,
        maximum: 60,
      ),
    );
  }
}

enum FacialCalibrationDatasetType {
  standardDatabase,
  patientSpecificCalibratedDatabase,
}

class NeutralFaceBaselineRepository {
  NeutralFaceBaselineRepository(this._preferences);

  static const _key = 'monitor.neutral_face_baseline';
  static const _activeDatasetKey = 'monitor.facial_active_dataset_type';
  final SharedPreferences _preferences;

  FacialCalibrationDatasetType getActiveDatasetType() {
    final val = _preferences.getString(_activeDatasetKey);
    if (val == 'patient') {
      return FacialCalibrationDatasetType.patientSpecificCalibratedDatabase;
    }
    return FacialCalibrationDatasetType.standardDatabase;
  }

  Future<void> setActiveDatasetType(FacialCalibrationDatasetType type) async {
    await _preferences.setString(
      _activeDatasetKey,
      type == FacialCalibrationDatasetType.patientSpecificCalibratedDatabase
          ? 'patient'
          : 'standard',
    );
  }

  NeutralFaceBaseline getEffectiveBaseline() {
    if (getActiveDatasetType() ==
        FacialCalibrationDatasetType.patientSpecificCalibratedDatabase) {
      return load() ?? NeutralFaceBaseline.standard;
    }
    return NeutralFaceBaseline.standard;
  }

  NeutralFaceBaseline? load() {
    final raw = _preferences.getString(_key);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return NeutralFaceBaseline.fromJson(
        Map<String, Object?>.from(decoded),
      );
    } on Object {
      return null;
    }
  }

  Future<void> save(NeutralFaceBaseline baseline) async {
    await _preferences.setString(_key, jsonEncode(baseline.toJson()));
    await setActiveDatasetType(
      FacialCalibrationDatasetType.patientSpecificCalibratedDatabase,
    );
  }

  Future<void> clear() async {
    await _preferences.remove(_key);
    await setActiveDatasetType(FacialCalibrationDatasetType.standardDatabase);
  }
}

class CalibratedPhraseRepository {
  CalibratedPhraseRepository(this._preferences);

  static const _key = 'monitor.calibrated_phrases';
  static const _customModeKey = 'monitor.is_custom_mode';
  final SharedPreferences _preferences;

  bool get isCustomMode => _preferences.getBool(_customModeKey) ?? false;

  Future<void> setCustomMode(bool custom) async {
    await _preferences.setBool(_customModeKey, custom);
  }

  List<CalibratedPhrase> load() {
    final raw = _preferences.getString(_key);
    if (raw == null) return _defaultPhrases();
    try {
      final decoded = jsonDecode(raw) as List<Object?>;
      final loaded = decoded
          .whereType<Map<String, Object?>>()
          .map(CalibratedPhrase.fromJson)
          .toList(growable: false);
      return loaded.isEmpty ? _defaultPhrases() : loaded;
    } on Object {
      return _defaultPhrases();
    }
  }

  List<CalibratedPhrase> _defaultPhrases() {
    return const [
      CalibratedPhrase(
        signal: PatientSignalKind.blink,
        key: 'blink',
        phrase: 'I need some help',
        minimumConfidence: 0.7375,
        dwell: Duration(milliseconds: 100),
        sensitivity: 0.75,
      ),
      CalibratedPhrase(
        signal: PatientSignalKind.mouthOpen,
        key: 'mouthOpen',
        phrase: 'I would like some water',
        minimumConfidence: 0.7375,
        dwell: Duration(milliseconds: 600),
        sensitivity: 0.75,
      ),
      CalibratedPhrase(
        signal: PatientSignalKind.smile,
        key: 'smile',
        phrase: 'Thank you',
        minimumConfidence: 0.7375,
        dwell: Duration(milliseconds: 600),
        sensitivity: 0.75,
      ),
      CalibratedPhrase(
        signal: PatientSignalKind.eyebrowsUp,
        key: 'eyebrowsUp',
        phrase: 'Yes',
        minimumConfidence: 0.72,
        dwell: Duration(milliseconds: 700),
        sensitivity: 0.80,
      ),
      CalibratedPhrase(
        signal: PatientSignalKind.slowBlink,
        key: 'slowBlink',
        phrase: 'Please rest a moment',
        minimumConfidence: 0.7375,
        dwell: Duration(milliseconds: 800),
        sensitivity: 0.75,
      ),
    ];
  }

  Future<void> save(CalibratedPhrase phrase) async {
    // A signal can only resolve to one spoken phrase. Replacing by key alone
    // left an older mapping active whenever a caregiver changed the key.
    final current = load()
        .where((item) => item.key != phrase.key && item.signal != phrase.signal)
        .toList();
    current.add(phrase);
    await _preferences.setString(
      _key,
      jsonEncode(current.map((item) => item.toJson()).toList()),
    );
    await setCustomMode(true);
  }

  Future<void> deleteByKey(String key) async {
    final updated = load().where((item) => item.key != key).toList();
    await _preferences.setString(
      _key,
      jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> remove(PatientSignalKind signal) async {
    final updated = load().where((item) => item.signal != signal).toList();
    await _preferences.setString(
      _key,
      jsonEncode(updated.map((item) => item.toJson()).toList()),
    );
  }

  Future<void> resetToDefaults() async {
    await _preferences.remove(_key);
    await setCustomMode(false);
  }

  String exportProfileJson({String profileName = 'Default Patient Profile'}) {
    final phrases = load();
    final data = {
      'schema_version': 'fingerspeak-v1',
      'profile_name': profileName,
      'exported_at': DateTime.now().toUtc().toIso8601String(),
      'is_custom_profile': isCustomMode,
      'phrases': phrases.map((p) => p.toJson()).toList(),
    };
    return const JsonEncoder.withIndent('  ').convert(data);
  }

  Future<int> importProfileJson(String jsonString) async {
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map<String, dynamic> &&
          decoded is! Map<Object?, Object?>) {
        throw const FormatException('Invalid JSON profile format.');
      }
      final rawPhrases = (decoded as Map)['phrases'];
      if (rawPhrases is! List) {
        throw const FormatException('Missing phrases list in profile JSON.');
      }
      final imported = <CalibratedPhrase>[];
      for (final item in rawPhrases) {
        if (item is Map<String, Object?>) {
          imported.add(CalibratedPhrase.fromJson(item));
        } else if (item is Map) {
          imported
              .add(CalibratedPhrase.fromJson(Map<String, Object?>.from(item)));
        }
      }
      if (imported.isEmpty) {
        throw const FormatException(
            'No valid phrases found in imported profile.');
      }
      await _preferences.setString(
        _key,
        jsonEncode(imported.map((item) => item.toJson()).toList()),
      );
      await setCustomMode(true);
      return imported.length;
    } catch (e) {
      rethrow;
    }
  }
}

class EdgeRiskConfirmationGate {
  EdgeRiskConfirmationGate({
    DateTime Function()? now,
    this.window = const Duration(seconds: 10),
  }) : _now = now ?? DateTime.now;

  static final _emergencyPattern = RegExp(
    r"\b(emergency|ambulance|choking|chest pain|heart attack|stroke|seizure|overdose|unconscious|severe bleeding|not breathing|difficulty breathing|cannot breathe|can't breathe|cant breathe|fire|call (?:999|911|112|the police)|help me now|urgent help)\b",
    caseSensitive: false,
  );

  final DateTime Function() _now;
  final Duration window;
  final Map<String, _EdgeRiskArm> _arms = {};

  static bool isEmergencyRiskText(String text) =>
      _emergencyPattern.hasMatch(text.trim());

  bool permits(CalibratedPhrase phrase, PatientSignal signal) {
    if (!isEmergencyRiskText(phrase.phrase) &&
        signal.kind != PatientSignalKind.seizureAlert) {
      return true;
    }
    final eventId = signal.sourceLabel;
    if (eventId == null || eventId.isEmpty) return false;

    final now = _now().toUtc();
    final armed = _arms[phrase.key];
    if (armed == null ||
        now.isBefore(armed.receivedAt) ||
        now.difference(armed.receivedAt) > window) {
      _arms[phrase.key] = _EdgeRiskArm(eventId, now);
      return false;
    }
    if (armed.eventId == eventId) return false;
    _arms.remove(phrase.key);
    return true;
  }

  void clear() => _arms.clear();
}

class _EdgeRiskArm {
  const _EdgeRiskArm(this.eventId, this.receivedAt);

  final String eventId;
  final DateTime receivedAt;
}

class RecognitionTriggerController {
  RecognitionTriggerController({
    required CalibratedPhraseRepository repository,
    required PatientVoiceService voice,
    required PiDeviceClient pi,
    required String locale,
    this.caregiverNotifications,
    this.cooldown = const Duration(seconds: 3),
    this.faceBurstCooldown = const Duration(milliseconds: 650),
    EdgeRiskConfirmationGate? edgeRiskGate,
  })  : _repository = repository,
        _voice = voice,
        _pi = pi,
        _locale = locale,
        _edgeRiskGate = edgeRiskGate ?? EdgeRiskConfirmationGate();

  final CalibratedPhraseRepository _repository;
  final PatientVoiceService _voice;
  final PiDeviceClient _pi;
  final String _locale;
  final CaregiverNotificationService? caregiverNotifications;
  final EdgeRiskConfirmationGate _edgeRiskGate;
  final Duration cooldown;
  final Duration faceBurstCooldown;
  final _spoken = StreamController<CalibratedPhrase>.broadcast();
  final Map<PatientSignalKind, DateTime> _candidateSince = {};
  final Map<PatientSignalKind, DateTime> _candidateLastSeen = {};
  final Map<PatientSignalKind, DateTime> _lastSpoken = {};
  final Map<PatientSignalKind, DateTime> _lastSuppressedAt = {};
  DateTime? _lastLocalFaceIntent;
  int _calibrationSessions = 0;

  Stream<CalibratedPhrase> get spokenPhrases => _spoken.stream;
  List<CalibratedPhrase> get phrases => _repository.load();
  bool get isCustomMode => _repository.isCustomMode;
  bool get isCalibrationSuppressed => _calibrationSessions > 0;

  void beginCalibrationSession() {
    if (_calibrationSessions == 0) _lastSuppressedAt.clear();
    _calibrationSessions++;
    _candidateSince.clear();
    _candidateLastSeen.clear();
    _lastLocalFaceIntent = null;
  }

  void endCalibrationSession() {
    if (_calibrationSessions > 0) _calibrationSessions--;
    _candidateSince.clear();
    _candidateLastSeen.clear();
    _lastLocalFaceIntent = null;
  }

  Future<void> setCustomMode(bool custom) => _repository.setCustomMode(custom);
  Future<void> resetToDefaults() => _repository.resetToDefaults();

  Future<void> save(CalibratedPhrase phrase) => _repository.save(phrase);

  Future<void> deleteByKey(String key) => _repository.deleteByKey(key);

  Future<void> remove(PatientSignalKind signal) => _repository.remove(signal);

  String exportProfileJson({String profileName = 'Default Patient Profile'}) =>
      _repository.exportProfileJson(profileName: profileName);

  Future<int> importProfileJson(String jsonString) =>
      _repository.importProfileJson(jsonString);

  Future<void> ingest(PatientSignal signal) => _ingest(signal, fromEdge: false);

  Future<void> ingestEdge(PatientSignal signal) =>
      _ingest(signal, fromEdge: true);

  Future<void> _ingest(
    PatientSignal signal, {
    required bool fromEdge,
  }) async {
    if (signal.kind == PatientSignalKind.seizureAlert) {
      unawaited(caregiverNotifications?.notifyEmergency(
        'Sudden Seizure Detected',
        'Abnormal muscle tremor & motor spasm detected by wheelchair unit.',
        signalKind: signal.kind,
        urgency: AlertUrgency.emergency,
      ));
    }
    if (!fromEdge && isCalibrationSuppressed) {
      _lastSuppressedAt[signal.kind] = signal.observedAt;
      _clearCandidate(signal.kind);
      return;
    }
    if (!fromEdge) {
      final suppressedAt = _lastSuppressedAt[signal.kind];
      if (suppressedAt != null) {
        final gap = signal.observedAt.difference(suppressedAt);
        if (gap.isNegative || gap <= const Duration(milliseconds: 2500)) {
          _clearCandidate(signal.kind);
          return;
        }
        _lastSuppressedAt.remove(signal.kind);
      }
    }

    final matches = phrases.where((phrase) => phrase.signal == signal.kind);
    if (matches.isEmpty) return;
    final phrase = matches.first;
    if (signal.confidence < phrase.minimumConfidence) {
      _clearCandidate(signal.kind);
      return;
    }

    // Edge intent events have already passed the edge device's calibrated
    // hold/debounce gate. Applying the local dwell a second time made valid
    // one-shot edge events impossible to execute.
    if (!fromEdge && !_localDwellSatisfied(phrase, signal)) return;

    final faceDerived = signal.kind.category == SignalCategory.eyes ||
        signal.kind.category == SignalCategory.face ||
        signal.kind.category == SignalCategory.head;
    final emergencyRisk = signal.kind == PatientSignalKind.seizureAlert ||
        EdgeRiskConfirmationGate.isEmergencyRiskText(phrase.phrase);
    if (!fromEdge && faceDerived && !emergencyRisk) {
      final previousFaceIntent = _lastLocalFaceIntent;
      if (previousFaceIntent != null &&
          !signal.observedAt.isBefore(previousFaceIntent) &&
          signal.observedAt.difference(previousFaceIntent) <
              faceBurstCooldown) {
        _clearCandidate(signal.kind);
        return;
      }
    }

    final last = _lastSpoken[signal.kind];
    if (last != null && signal.observedAt.difference(last) < cooldown) return;
    if (fromEdge && !_edgeRiskGate.permits(phrase, signal)) {
      _clearCandidate(signal.kind);
      return;
    }

    _lastSpoken[signal.kind] = signal.observedAt;
    if (!fromEdge && faceDerived && !emergencyRisk) {
      _lastLocalFaceIntent = signal.observedAt;
    }
    _clearCandidate(signal.kind);

    // 1. Voice playback immediately on device
    await _voice.speakPhrase(phrase.key, phrase.phrase);

    // 2. Synchronize to wheelchair display
    if (_pi.state == PiConnectionState.connected) {
      _pi.sendCaption(phrase.phrase, language: _locale);
    }

    // 3. Notify caregiver
    unawaited(caregiverNotifications?.notifyPatientSpoken(
      phrase.phrase,
      signalKind: phrase.signal,
    ));

    _spoken.add(phrase);
  }

  bool _localDwellSatisfied(
    CalibratedPhrase phrase,
    PatientSignal signal,
  ) {
    if (phrase.dwell <= Duration.zero) return true;

    // Detectors for temporal gestures (for example a held blink) can attach
    // the already-observed active duration. This lets one confirmed event
    // satisfy dwell without requiring the patient to perform it twice.
    final activeDuration = signal.metadata?['active_duration_ms'];
    if (activeDuration is num &&
        activeDuration.isFinite &&
        activeDuration >= phrase.dwell.inMilliseconds) {
      return true;
    }

    final previous = _candidateLastSeen[signal.kind];
    final maximumGap = Duration(
      milliseconds: phrase.dwell.inMilliseconds.clamp(1000, 2500).toInt(),
    );
    if (previous == null ||
        signal.observedAt.isBefore(previous) ||
        signal.observedAt.difference(previous) > maximumGap) {
      _candidateSince[signal.kind] = signal.observedAt;
    }
    _candidateLastSeen[signal.kind] = signal.observedAt;
    final firstSeen = _candidateSince.putIfAbsent(
      signal.kind,
      () => signal.observedAt,
    );
    return signal.observedAt.difference(firstSeen) >= phrase.dwell;
  }

  void _clearCandidate(PatientSignalKind kind) {
    _candidateSince.remove(kind);
    _candidateLastSeen.remove(kind);
  }

  Future<void> speakNow(CalibratedPhrase phrase) async {
    await _voice.speakPhrase(phrase.key, phrase.phrase);
    if (_pi.state == PiConnectionState.connected) {
      _pi.sendCaption(phrase.phrase, language: _locale);
    }
    unawaited(caregiverNotifications?.notifyPatientSpoken(
      phrase.phrase,
      signalKind: phrase.signal,
    ));
    _spoken.add(phrase);
  }

  void clearEdgeArmState() {
    _edgeRiskGate.clear();
    _candidateSince.clear();
    _candidateLastSeen.clear();
  }

  Future<void> dispose() {
    clearEdgeArmState();
    _lastSuppressedAt.clear();
    return _spoken.close();
  }
}
