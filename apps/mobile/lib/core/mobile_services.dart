import 'dart:async';

import 'package:fingerspeak_mobile/core/app_config.dart';
import 'package:fingerspeak_mobile/data/asha_api_client.dart';
import 'package:fingerspeak_mobile/data/cloud_api_client.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/models/personal_access_profile_repository.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/services/calibration_service.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/cloud_alert_repository.dart';
import 'package:fingerspeak_mobile/services/cloud_sync_service.dart';
import 'package:fingerspeak_mobile/services/companion_controller.dart';
import 'package:fingerspeak_mobile/services/multimodal_fusion_engine.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
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
  });

  final AppConfig config;
  final UserRoleRepository roleRepository;
  final PatientAccessMethodRepository patientAccessMethodRepository;
  final PersonalAccessProfileRepository accessProfileRepository;
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
  StreamSubscription<Object?>? _signalSubscription;
  StreamSubscription<PiConnectionState>? _piStateSubscription;
  StreamSubscription<PatientSignal>? _piSignalSubscription;

  static Future<MobileServices> create() async {
    final config = AppConfig.fromEnvironment();
    final preferences = await SharedPreferences.getInstance();
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
    final pi = PiDeviceClient(
      endpoint: config.piUri,
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

    final result = MobileServices._(
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
    );
    result._signalSubscription = monitor.signals.listen((signal) {
      unawaited(recognition.ingest(signal));
    });
    result._piStateSubscription = pi.states.listen(result._handlePiState);
    final currentRole = roleRepository.load() ?? UserRole.patient;
    await companion.start(role: currentRole);
    return result;
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
    return MobileServices._(
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

  Future<void> useStandardCalibrationProfile() async {
    await neutralBaselineRepository.clear();
    _applyNeutralBaseline(monitor, NeutralFaceBaseline.standard);
    await recognition.resetToDefaults();
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
    companion.dispose();
    await recognition.dispose();
    await monitor.dispose();
    await pi.dispose();
    await caregiverNotifications.dispose();
    await voice.dispose();
    cloudAlerts.dispose();
    cloudApi.close();
  }
}
