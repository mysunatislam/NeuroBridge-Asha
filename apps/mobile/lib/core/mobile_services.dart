import 'dart:async';

import 'package:fingerspeak_mobile/core/app_config.dart';
import 'package:fingerspeak_mobile/data/asha_api_client.dart';
import 'package:fingerspeak_mobile/data/cloud_api_client.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/intent/intent_recognition_service.dart';
import 'package:fingerspeak_mobile/intent/patient_profile.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/models/patient_registry_repository.dart';
import 'package:fingerspeak_mobile/models/personal_access_profile_repository.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/services/calibration_service.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/cloud_alert_repository.dart';
import 'package:fingerspeak_mobile/services/cloud_sync_service.dart';
import 'package:fingerspeak_mobile/services/companion_controller.dart';
import 'package:fingerspeak_mobile/services/multimodal_fusion_engine.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:fingerspeak_mobile/services/local_peer_sync_service.dart';
import 'package:fingerspeak_mobile/services/patient_roster_service.dart';
import 'package:fingerspeak_mobile/services/reminder_service.dart';
import 'package:fingerspeak_mobile/services/session_metrics_service.dart';
import 'package:fingerspeak_mobile/services/voice_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MobileServices {
  MobileServices._({
    required this.config,
    required this.roleRepository,
    required this.patientAccessMethodRepository,
    required this.accessProfileRepository,
    required this.voice,
    required this.reminders,
    required this.caregiverNotifications,
    required this.pi,
    required this.monitor,
    required this.recognition,
    required this.neutralBaselineRepository,
    required this.companion,
    required this.sessionMetrics,
    required this.cloudApi,
    required this.cloudSync,
    required this.cloudAlerts,
    required this.fusionEngine,
    required this.ashaGuide,
    required this.localPeerSync,
    required this.patientRoster,
    required this.patientRegistry,
    required this.intentRecognition,
    required SharedPreferences preferences,
  }) : _preferences = preferences;

  static const intentEnabledKey = 'intent.enabled';

  final SharedPreferences _preferences;
  final AppConfig config;
  final UserRoleRepository roleRepository;
  final PatientAccessMethodRepository patientAccessMethodRepository;
  final PersonalAccessProfileRepository accessProfileRepository;
  final PatientRegistryRepository patientRegistry;
  final PatientVoiceService voice;
  final LocalReminderService reminders;
  final CaregiverNotificationService caregiverNotifications;
  final PiDeviceClient pi;
  final PatientSignalMonitor monitor;
  final RecognitionTriggerController recognition;
  final NeutralFaceBaselineRepository neutralBaselineRepository;
  final CompanionController companion;
  final SessionMetricsService sessionMetrics;
  final CloudApiClient cloudApi;
  final CloudSyncService cloudSync;
  final CloudAlertRepository cloudAlerts;
  final MultimodalFusionEngine fusionEngine;
  final AshaGuideService ashaGuide;
  final LocalPeerSyncService localPeerSync;
  final PatientRosterService patientRoster;

  /// Offline patient-adaptive intent recognition (movement != command).
  /// While enabled, live face signals only reach speech after the temporal
  /// pipeline, the patient profile and the confidence gate agree.
  final IntentRecognitionService intentRecognition;
  StreamSubscription<Object?>? _signalSubscription;
  StreamSubscription<PiConnectionState>? _piStateSubscription;
  StreamSubscription<PatientSignal>? _piSignalSubscription;

  static Future<MobileServices> create() async {
    final config = AppConfig.fromEnvironment();
    final preferences = await SharedPreferences.getInstance();
    final savedGeminiKey = preferences.getString('gemini.api_key');
    if (savedGeminiKey == null || savedGeminiKey.trim().isEmpty) {
      if (config.geminiApiKey.isNotEmpty) {
        await preferences.setString('gemini.api_key', config.geminiApiKey);
      }
    }
    final roleRepository = UserRoleRepository(preferences);
    final patientAccessMethodRepository =
        PatientAccessMethodRepository(preferences);
    final recordings = RecordedPhraseRepository(preferences);
    final voice = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(preferences),
      recordings: recordings,
    );
    await voice.initialize(locale: config.locale);
    final reminders = LocalReminderService(preferences);
    try {
      await reminders.initialize();
    } on Object {
      // Notification permission/plugin failures must not block communication.
    }
    final caregiverNotifications = CaregiverNotificationService(preferences);
    try {
      await caregiverNotifications.initialize();
    } on Object {
      // Best-effort local notification init.
    }
    final savedPiUrl = preferences.getString('pi.ws_url');
    var piUri = config.piUri;
    if (savedPiUrl != null && savedPiUrl.trim().isNotEmpty) {
      try {
        final parsed = Uri.parse(savedPiUrl.trim());
        if (parsed.hasScheme && {'ws', 'wss'}.contains(parsed.scheme)) {
          piUri = parsed;
        }
      } on FormatException {
        // Fall back to default config endpoint.
      }
    }
    final pi = PiDeviceClient(
      endpoint: piUri,
      deviceId: config.piDeviceId,
    );
    final neutralBaselineRepository =
        NeutralFaceBaselineRepository(preferences);
    final monitor = MlKitPatientSignalMonitor();
    _applyNeutralBaseline(
      monitor,
      neutralBaselineRepository.load() ?? NeutralFaceBaseline.standard,
    );
    final recognition = RecognitionTriggerController(
      repository: CalibratedPhraseRepository(preferences),
      voice: voice,
      pi: pi,
      locale: config.locale,
      caregiverNotifications: caregiverNotifications,
    );
    _applySignalSensitivities(monitor, recognition.phrases);
    final companion = CompanionController(
      api: AshaApiClient(
        baseUri: config.apiUri,
        geminiApiKeyProvider: () async {
          final storedKey = preferences.getString('gemini.api_key');
          if (storedKey != null && storedKey.trim().isNotEmpty) {
            return storedKey.trim();
          }
          return config.geminiApiKey.isNotEmpty ? config.geminiApiKey : null;
        },
        geminiModel: config.geminiModel,
        aiProviderProvider: () async => preferences.getString('ai.provider'),
        customBaseUrlProvider: () async => preferences.getString('ai.base_url'),
        customApiKeyProvider: () async => preferences.getString('ai.api_key'),
        customModelProvider: () async => preferences.getString('ai.model'),
      ),
      voice: voice,
      locale: config.locale,
    );
    final sessionMetrics = SessionMetricsService();
    final cloudApi = CloudApiClient(baseUri: config.apiUri);
    final cloudSync = CloudSyncService(
      preferences: preferences,
      apiClient: cloudApi,
    );
    final cloudAlerts = CloudAlertRepository(apiClient: cloudApi);
    final accessProfileRepository =
        PersonalAccessProfileRepository(preferences);
    final fusionEngine = MultimodalFusionEngine(
      onIntentExecuted: (event) {
        voice.speakPhrase('fused_intent', event.intent);
      },
      onConfirmationPromptRequested: (intent, conf) {
        voice.speakSystemPrompt('Confirm $intent? Blink or tilt head.');
      },
    );
    final ashaGuide = AshaGuideService(preferences);
    final localPeerSync = LocalPeerSyncService();
    final patientRoster = PatientRosterService(
      preferences: preferences,
      peerSync: localPeerSync,
    );
    final patientRegistry = PatientRegistryRepository(preferences);
    final intentRecognition = _buildIntentRecognition(
      preferences: preferences,
      monitor: monitor,
      recognition: recognition,
      voice: voice,
      caregiverNotifications: caregiverNotifications,
    );

    final result = MobileServices._(
      preferences: preferences,
      intentRecognition: intentRecognition,
      config: config,
      roleRepository: roleRepository,
      patientAccessMethodRepository: patientAccessMethodRepository,
      accessProfileRepository: accessProfileRepository,
      voice: voice,
      reminders: reminders,
      caregiverNotifications: caregiverNotifications,
      pi: pi,
      monitor: monitor,
      recognition: recognition,
      neutralBaselineRepository: neutralBaselineRepository,
      companion: companion,
      sessionMetrics: sessionMetrics,
      cloudApi: cloudApi,
      cloudSync: cloudSync,
      cloudAlerts: cloudAlerts,
      fusionEngine: fusionEngine,
      ashaGuide: ashaGuide,
      localPeerSync: localPeerSync,
      patientRoster: patientRoster,
      patientRegistry: patientRegistry,
    );
    result._signalSubscription = monitor.signals.listen((signal) {
      if (result.shouldBypassIntentPipeline(signal)) {
        unawaited(recognition.ingest(signal));
      }
    });
    result._piStateSubscription = pi.states.listen(result._handlePiState);
    final currentRole = roleRepository.load() ?? UserRole.patient;
    await companion.start(role: currentRole);
    unawaited(intentRecognition.start());
    return result;
  }

  static IntentRecognitionService _buildIntentRecognition({
    required SharedPreferences preferences,
    required PatientSignalMonitor monitor,
    required RecognitionTriggerController recognition,
    required PatientVoiceService voice,
    required CaregiverNotificationService? caregiverNotifications,
  }) {
    return IntentRecognitionService(
      observations: monitor.observations,
      profileRepository: PatientProfileRepository(preferences),
      enabled: preferences.getBool(intentEnabledKey) ?? true,
      onExecute: (signal, verdict) {
        // Verified command: hand it to the existing phrase/caption/notify path.
        unawaited(recognition.ingest(signal));
      },
      onConfirmationPrompt: (command, prompt, confidence) {
        unawaited(voice.speakSystemPrompt(prompt));
      },
      onAlert: (label, probability) {
        unawaited(caregiverNotifications?.notifyEmergency(
          'Possible involuntary movement',
          'On-device analysis flagged ${label.replaceAll('_', ' ')} '
              '(${(probability * 100).round()}%). Commands are paused; please check the patient.',
          signalKind: PatientSignalKind.seizureAlert,
          urgency: AlertUrgency.emergency,
        ));
      },
    );
  }

  /// Legacy single-signal triggers stay available for simulated/debug signals
  /// and for the explicit seizure alert; live face movements go through the
  /// intent pipeline whenever it is enabled.
  bool shouldBypassIntentPipeline(PatientSignal signal) {
    if (!intentRecognition.enabled) return true;
    if (signal.kind == PatientSignalKind.seizureAlert) return true;
    if (signal.sourceLabel == 'simulated') return true;
    final category = signal.kind.category;
    return category != SignalCategory.eyes &&
        category != SignalCategory.face &&
        category != SignalCategory.head;
  }

  bool get intentRecognitionEnabled => intentRecognition.enabled;

  Future<void> setIntentRecognitionEnabled(bool enabled) async {
    intentRecognition.setEnabled(enabled);
    await _preferences.setBool(intentEnabledKey, enabled);
  }

  static Future<MobileServices> forTest({
    AppConfig? config,
    SharedPreferences? preferences,
    PatientSignalMonitor? monitor,
  }) async {
    final cfg = config ?? AppConfig.fromEnvironment();
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.setBool('voice.auto_speak', false);
    final roleRepo = UserRoleRepository(prefs);
    final patientAccessMethodRepository = PatientAccessMethodRepository(prefs);
    final accessProfileRepository = PersonalAccessProfileRepository(prefs);
    final voice = PatientVoiceService(
      preferenceRepository: VoicePreferenceRepository(prefs),
      recordings: RecordedPhraseRepository(prefs),
    );
    final notifications = CaregiverNotificationService(prefs);
    final pi = PiDeviceClient(
      endpoint: cfg.piUri,
      deviceId: cfg.piDeviceId,
    );
    final neutralBaselineRepository = NeutralFaceBaselineRepository(prefs);
    final mon = monitor ?? NoOpPatientSignalMonitor();
    _applyNeutralBaseline(
      mon,
      neutralBaselineRepository.load() ?? NeutralFaceBaseline.standard,
    );
    final recognition = RecognitionTriggerController(
      repository: CalibratedPhraseRepository(prefs),
      voice: voice,
      pi: pi,
      locale: cfg.locale,
      caregiverNotifications: notifications,
    );
    _applySignalSensitivities(mon, recognition.phrases);
    final companion = CompanionController(
      api: AshaApiClient(baseUri: cfg.apiUri),
      voice: voice,
      locale: cfg.locale,
    );
    final cloudApi = CloudApiClient(baseUri: cfg.apiUri);
    final fusionEngine = MultimodalFusionEngine(
      onIntentExecuted: (_) {},
      onConfirmationPromptRequested: (_, __) {},
    );
    final ashaGuide = AshaGuideService(prefs);
    final localPeerSync = LocalPeerSyncService();
    final patientRoster = PatientRosterService(
      preferences: prefs,
      peerSync: localPeerSync,
      autoStartHeartbeat: false,
    );
    final patientRegistry = PatientRegistryRepository(prefs);
    final intentRecognition = _buildIntentRecognition(
      preferences: prefs,
      monitor: mon,
      recognition: recognition,
      voice: voice,
      caregiverNotifications: notifications,
    );
    return MobileServices._(
      preferences: prefs,
      intentRecognition: intentRecognition,
      config: cfg,
      roleRepository: roleRepo,
      patientAccessMethodRepository: patientAccessMethodRepository,
      accessProfileRepository: accessProfileRepository,
      voice: voice,
      reminders: LocalReminderService(prefs),
      caregiverNotifications: notifications,
      pi: pi,
      monitor: mon,
      recognition: recognition,
      neutralBaselineRepository: neutralBaselineRepository,
      companion: companion,
      sessionMetrics: SessionMetricsService(),
      cloudApi: cloudApi,
      cloudSync: CloudSyncService(preferences: prefs, apiClient: cloudApi),
      cloudAlerts: CloudAlertRepository(apiClient: cloudApi),
      fusionEngine: fusionEngine,
      ashaGuide: ashaGuide,
      localPeerSync: localPeerSync,
      patientRoster: patientRoster,
      patientRegistry: patientRegistry,
    );
  }

  void _handlePiState(PiConnectionState state) {
    if (state == PiConnectionState.connected) {
      _piSignalSubscription ??= pi.patientSignals.listen((signal) {
        if (pi.state == PiConnectionState.connected) {
          unawaited(recognition.ingestEdge(signal));
        }
      });
      return;
    }
    final subscription = _piSignalSubscription;
    _piSignalSubscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    recognition.clearEdgeArmState();
  }

  Future<void> saveNeutralFaceBaseline(NeutralFaceBaseline baseline) async {
    await neutralBaselineRepository.save(baseline);
    _applyNeutralBaseline(monitor, baseline);
    await recognition.setCustomMode(true);
  }

  Future<void> saveCalibratedPhrase(CalibratedPhrase phrase) async {
    await recognition.save(phrase);
    refreshFaceSignalSensitivities();
  }

  Future<int> importCalibrationProfile(String jsonText) async {
    final count = await recognition.importProfileJson(jsonText);
    refreshFaceSignalSensitivities();
    return count;
  }

  void previewFaceSignalSensitivity(
    PatientSignalKind signal,
    double sensitivity,
  ) {
    final values = <PatientSignalKind, double>{
      for (final phrase in recognition.phrases)
        phrase.signal: phrase.sensitivity,
      signal: sensitivity,
    };
    monitor.setSignalSensitivities(values);
  }

  void refreshFaceSignalSensitivities() {
    _applySignalSensitivities(monitor, recognition.phrases);
  }

  Future<void> useStandardCalibrationProfile() async {
    await neutralBaselineRepository.clear();
    _applyNeutralBaseline(monitor, NeutralFaceBaseline.standard);
    await recognition.resetToDefaults();
    refreshFaceSignalSensitivities();
  }

  static void _applySignalSensitivities(
    PatientSignalMonitor monitor,
    List<CalibratedPhrase> phrases,
  ) {
    monitor.setSignalSensitivities({
      for (final phrase in phrases) phrase.signal: phrase.sensitivity,
    });
  }

  static void _applyNeutralBaseline(
    PatientSignalMonitor monitor,
    NeutralFaceBaseline baseline,
  ) {
    monitor.setNeutralBaseline(
      eyebrowDistance: baseline.eyebrowDistance,
      mouthDistance: baseline.mouthDistance,
      leftEyeOpenness: baseline.leftEyeOpenness,
      rightEyeOpenness: baseline.rightEyeOpenness,
      smileProbability: baseline.smileProbability,
      headYaw: baseline.headYaw,
      headPitch: baseline.headPitch,
    );
  }

  Future<void> dispose() async {
    await _signalSubscription?.cancel();
    await _piStateSubscription?.cancel();
    await _piSignalSubscription?.cancel();
    intentRecognition.dispose();
    companion.dispose();
    await recognition.dispose();
    await monitor.dispose();
    await pi.dispose();
    await caregiverNotifications.dispose();
    await voice.dispose();
    cloudAlerts.dispose();
    cloudApi.close();
    ashaGuide.dispose();
    localPeerSync.dispose();
    patientRoster.dispose();
  }
}
