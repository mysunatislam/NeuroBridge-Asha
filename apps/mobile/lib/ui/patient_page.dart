import 'dart:async';

import 'package:camera/camera.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/models/personal_access_profile.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/ability_assessment_page.dart';
import 'package:fingerspeak_mobile/ui/asha_chat_sheet.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:fingerspeak_mobile/ui/single_switch_scanning_view.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class PatientPage extends StatefulWidget {
  const PatientPage({
    required this.services,
    this.isActive = true,
    super.key,
  });

  final MobileServices services;
  final bool isActive;

  @override
  State<PatientPage> createState() => _PatientPageState();
}

class _PatientPageState extends State<PatientPage> {
  MonitorStatus _monitorStatus = const MonitorStatus.stopped();
  PatientSignal? _lastSignal;
  CalibratedPhrase? _lastPhrase;
  bool _waterEnabled = true;
  bool _busy = false;
  Future<void>? _monitorOperation;
  bool _configuringAccessMethod = false;
  bool _handRouteOpen = false;
  PatientAccessMethod? _accessMethod;
  StreamSubscription<MonitorStatus>? _monitorSubscription;
  StreamSubscription<PatientSignal>? _signalSubscription;
  StreamSubscription<CalibratedPhrase>? _phraseSubscription;

  @override
  void initState() {
    super.initState();
    _monitorStatus = widget.services.monitor.currentStatus;
    _waterEnabled = widget.services.reminders.waterRemindersEnabled;
    _accessMethod = widget.services.patientAccessMethodRepository.load();
    widget.services.patientAccessMethodRepository
        .addListener(_onAccessMethodChanged);
    _monitorSubscription = widget.services.monitor.statuses.listen((status) {
      if (mounted) setState(() => _monitorStatus = status);
    });
    _signalSubscription = widget.services.monitor.signals.listen((signal) {
      if (mounted) setState(() => _lastSignal = signal);
    });
    _phraseSubscription =
        widget.services.recognition.spokenPhrases.listen((phrase) {
      if (mounted) setState(() => _lastPhrase = phrase);
    });
    if (widget.isActive && !_configuringAccessMethod) {
      _scheduleAccessMethodConfiguration();
    }
  }

  @override
  void didUpdateWidget(PatientPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isActive && widget.isActive) {
      _scheduleAccessMethodConfiguration();
    } else if (oldWidget.isActive && !widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !widget.isActive) {
          unawaited(_toggleMonitoring(false));
        }
      });
    }
  }

  @override
  void dispose() {
    widget.services.patientAccessMethodRepository
        .removeListener(_onAccessMethodChanged);
    unawaited(_monitorSubscription?.cancel());
    unawaited(_signalSubscription?.cancel());
    unawaited(_phraseSubscription?.cancel());
    super.dispose();
  }

  void _onAccessMethodChanged() {
    if (!mounted) return;
    setState(() {
      _accessMethod = widget.services.patientAccessMethodRepository.load();
    });
    if (widget.isActive && !_configuringAccessMethod) {
      _scheduleAccessMethodConfiguration();
    }
  }

  void _scheduleAccessMethodConfiguration() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.isActive) {
        unawaited(_configureAccessMethod());
      }
    });
  }

  Future<void> _configureAccessMethod() async {
    if (_configuringAccessMethod || !widget.isActive) return;
    _configuringAccessMethod = true;
    try {
      var method = widget.services.patientAccessMethodRepository.load();
      if (method == null) {
        method = await _askFingerCapability();
        if (method == null || !mounted || !widget.isActive) return;
        await widget.services.patientAccessMethodRepository.save(method);
      }
      if (!mounted || !widget.isActive) return;
      setState(() => _accessMethod = method);
      await _activateAccessMethod(method);
    } finally {
      _configuringAccessMethod = false;
    }
  }

  Future<void> _openAssessmentWizard() async {
    final currentProfile = widget.services.accessProfileRepository.load();
    final completedProfile =
        await Navigator.of(context).push<PersonalAccessProfile>(
      MaterialPageRoute<PersonalAccessProfile>(
        builder: (_) => AbilityAssessmentPage(
          services: widget.services,
          initialProfile: currentProfile,
        ),
      ),
    );
    if (!mounted) return;
    setState(() {});
    final guide = widget.services.ashaGuide;
    if (completedProfile != null &&
        guide.isActive &&
        guide.step == AshaGuideStep.profile) {
      await guide.next();
    }
  }

  Future<PatientAccessMethod?> _askFingerCapability() {
    return showDialog<PatientAccessMethod>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        icon: const Icon(Icons.accessibility_new,
            color: Color(0xFF2DD4BF), size: 32),
        title: const Text('Can the patient intentionally move their fingers?'),
        content: const Text(
          'Choose the movement the patient can control reliably. You can change this later in Setup.',
        ),
        actions: [
          OutlinedButton.icon(
            onPressed: () {
              Navigator.pop(context);
              _openAssessmentWizard();
            },
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF2DD4BF)),
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Ability Assessment'),
          ),
          OutlinedButton.icon(
            onPressed: () => Navigator.pop(
              context,
              PatientAccessMethod.faceEyesAndHead,
            ),
            style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF94A3B8)),
            icon: const Icon(Icons.face_retouching_natural),
            label: const Text('No — use face & eyes'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(
              context,
              PatientAccessMethod.handGestures,
            ),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF2DD4BF),
                foregroundColor: Colors.black),
            icon: const Icon(Icons.pan_tool_alt),
            label: const Text('Yes — use fingers'),
          ),
        ],
      ),
    );
  }

  Future<void> _activateAccessMethod(PatientAccessMethod method) async {
    if (method == PatientAccessMethod.faceEyesAndHead) {
      await _toggleMonitoring(true);
      return;
    }

    await _toggleMonitoring(false);
    if (mounted && widget.isActive && !_handRouteOpen) {
      await _openHandCommunicator();
    }
  }

  Future<void> _openHandCommunicator() async {
    if (_handRouteOpen || !mounted) return;
    _handRouteOpen = true;
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => HandCalibrationPage(
            services: widget.services,
            mode: HandStudioMode.patientExecution,
          ),
        ),
      );
    } finally {
      _handRouteOpen = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _changeAccessMethod() async {
    final selected = await _askFingerCapability();
    if (selected == null) return;
    await widget.services.patientAccessMethodRepository.save(selected);
  }

  Future<void> _toggleMonitoring(bool enabled) async {
    final previous = _monitorOperation;
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // The requested state below remains authoritative after a failed op.
      }
    }
    if (mounted) setState(() => _busy = true);
    final operation = enabled
        ? widget.services.monitor.start()
        : widget.services.monitor.stop();
    _monitorOperation = operation;
    try {
      await operation;
    } finally {
      if (identical(_monitorOperation, operation)) _monitorOperation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleWater(bool enabled) async {
    await widget.services.reminders.setWaterRemindersEnabled(enabled);
    if (mounted) setState(() => _waterEnabled = enabled);
  }

  Future<void> _callCaregiver() async {
    final phone = widget.services.config.caregiverPhone.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Caregiver phone number not set. Configure in Setup tab.',
          ),
        ),
      );
      return;
    }
    final uri = Uri(scheme: 'tel', path: phone);
    if (!await launchUrl(uri)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This device could not open the phone dialer.'),
        ),
      );
    }
  }

  Future<void> _requestEmergencyHelp() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Request emergency help?'),
        content: const Text(
          'This will speak the urgent request aloud, show it on the wheelchair display, notify the caregiver, and open the emergency phone dialer.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFFB42318)),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Request Emergency Help'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    const message = 'Emergency help requested! Please assist immediately.';
    await widget.services.voice.speakAsha(message, force: true);
    if (widget.services.pi.state == PiConnectionState.connected) {
      widget.services.pi.showEmergency(
        message,
        language: widget.services.config.locale,
      );
    }
    await widget.services.caregiverNotifications.notifyEmergency(
      'Emergency SOS Triggered',
      'Patient requested urgent emergency help.',
      urgency: AlertUrgency.emergency,
    );
    if (mounted) await _callCaregiver();
  }

  Widget _buildCapabilityPending(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
      children: [
        const _PatientHeader(),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                const Icon(
                  Icons.accessibility_new,
                  size: 48,
                  color: Color(0xFF0B756A),
                ),
                const SizedBox(height: 12),
                Text(
                  'Choose the patient’s reliable movement',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'NeuroBridge Asha will open either hand-gesture communication or face, eye, and head monitoring.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                AshaGuideTarget(
                  step: AshaGuideStep.profile,
                  child: FilledButton(
                    onPressed: _configureAccessMethod,
                    child: const Text('Choose Input Method'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHandDashboard(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
      children: [
        const _PatientHeader(),
        const SizedBox(height: 18),
        _ReassuranceCard(
          online: widget.services.companion.online,
          onTap: () => showAshaChatSheet(
            context,
            widget.services.companion,
            role: UserRole.patient,
            voiceService: widget.services.voice,
            services: widget.services,
          ),
        ),
        const SizedBox(height: 16),
        Card(
          color: const Color(0xFF102522),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(
                  Icons.pan_tool_alt,
                  size: 58,
                  color: Color(0xFFA6E3D9),
                ),
                const SizedBox(height: 12),
                Text(
                  'Finger Gesture Communicator',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .titleLarge
                      ?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Uses the saved MediaPipe hand model locally. Hold a calibrated gesture to speak its phrase.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFFC9D9D5)),
                ),
                const SizedBox(height: 18),
                AshaGuideTarget(
                  step: AshaGuideStep.firstSession,
                  child: FilledButton.icon(
                    onPressed: _openHandCommunicator,
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('Open Hand Communicator'),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _changeAccessMethod,
                  icon: const Icon(Icons.swap_horiz),
                  label: const Text('Change Input Method'),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFFA6E3D9),
                  ),
                ),
                AshaGuideTarget(
                  step: AshaGuideStep.profile,
                  child: TextButton.icon(
                    onPressed: _openAssessmentWizard,
                    icon: const Icon(Icons.accessibility_new),
                    label: const Text('Retest Ability Profile'),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFF4FD1C5),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _PhraseCard(
          phrases: widget.services.recognition.phrases,
          lastPhrase: _lastPhrase,
          onSpeak: widget.services.recognition.speakNow,
        ),
        const SizedBox(height: 16),
        Card(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: SwitchListTile(
            value: _waterEnabled,
            onChanged: _toggleWater,
            secondary: const CircleAvatar(
              backgroundColor: Color(0xFFD9F1EC),
              child: Icon(
                Icons.water_drop_outlined,
                color: Color(0xFF0B756A),
              ),
            ),
            title: const Text('Gentle hydration reminder'),
            subtitle: const Text(
              'Asha gently reminds you hourly; drink only when safe.',
            ),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            onPressed: _callCaregiver,
            icon: const Icon(Icons.call),
            label: const Text(
              'Call My Caregiver',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFFB42318),
              foregroundColor: Colors.white,
            ),
            onPressed: _requestEmergencyHelp,
            icon: const Icon(Icons.emergency),
            label: const Text(
              'Emergency Help SOS',
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final profile = widget.services.accessProfileRepository.load();
    if (profile?.primaryModality == AccessModality.singleSwitchScanning) {
      return Scaffold(
        backgroundColor: const Color(0xFF0F172A),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1E293B),
          foregroundColor: Colors.white,
          title: const Text('Single-Switch Scanning',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          actions: [
            AshaGuideTarget(
              step: AshaGuideStep.profile,
              child: IconButton(
                icon: const Icon(Icons.accessibility_new,
                    color: Color(0xFF2DD4BF)),
                tooltip: 'Ability Assessment',
                onPressed: _openAssessmentWizard,
              ),
            ),
          ],
        ),
        body: SingleSwitchScanningView(services: widget.services),
      );
    }
    if (_accessMethod == null) return _buildCapabilityPending(context);
    if (_accessMethod == PatientAccessMethod.handGestures) {
      return _buildHandDashboard(context);
    }
    final monitoring = _monitorStatus.lifecycle == MonitorLifecycle.active ||
        _monitorStatus.lifecycle == MonitorLifecycle.starting;
    final controller = widget.services.monitor.cameraController;

    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
          sliver: SliverList.list(
            children: [
              const _PatientHeader(),
              const SizedBox(height: 18),
              _ReassuranceCard(
                online: widget.services.companion.online,
                onTap: () => showAshaChatSheet(
                  context,
                  widget.services.companion,
                  role: UserRole.patient,
                  voiceService: widget.services.voice,
                  services: widget.services,
                ),
              ),
              const SizedBox(height: 16),
              AshaGuideTarget(
                step: AshaGuideStep.profile,
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _openAssessmentWizard,
                    icon: const Icon(Icons.accessibility_new),
                    label: const Text('Open Patient Ability Profile'),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                color: const Color(0xFF102522),
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (monitoring &&
                        controller != null &&
                        controller.value.isInitialized)
                      Container(
                        height: 220,
                        color: Colors.black,
                        child: Stack(
                          fit: StackFit.expand,
                          alignment: Alignment.center,
                          children: [
                            Center(
                              child: AspectRatio(
                                aspectRatio: controller.value.aspectRatio > 0
                                    ? controller.value.aspectRatio
                                    : 4 / 3,
                                child: CameraPreview(controller),
                              ),
                            ),
                            Positioned(
                              top: 12,
                              left: 12,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: const Color(0xCC000000),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                      color: const Color(0xFF0B756A)),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.videocam,
                                        size: 14, color: Color(0xFF4ADE80)),
                                    SizedBox(width: 4),
                                    Text(
                                      'LIVE WEBCAM CV',
                                      style: TextStyle(
                                        color: Color(0xFF4ADE80),
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Center(
                              child: Container(
                                width: 140,
                                height: 170,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(70),
                                  border: Border.all(
                                    color: const Color(0x664ADE80),
                                    width: 1.5,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      const SizedBox(
                        height: 160,
                        child: Center(
                          child: Icon(
                            Icons.face_retouching_natural,
                            color: Color(0xFFA6E3D9),
                            size: 60,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'Continuous Multimodal Monitor',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(color: Colors.white),
                                ),
                              ),
                              ListenableBuilder(
                                listenable: widget.services.ashaGuide,
                                builder: (context, _) {
                                  final guide = widget.services.ashaGuide;
                                  if (guide.isActive &&
                                      guide.step == AshaGuideStep.firstSession) {
                                    return AshaGuideTarget(
                                      step: AshaGuideStep.firstSession,
                                      child: FilledButton.icon(
                                        key: const ValueKey(
                                            'asha-guide-start-face-session'),
                                        onPressed: _busy
                                            ? null
                                            : () async {
                                                if (!monitoring) {
                                                  await _toggleMonitoring(true);
                                                }
                                                if (!mounted) return;
                                                if (widget.services.monitor
                                                            .currentStatus.lifecycle ==
                                                        MonitorLifecycle.active &&
                                                    guide.isActive &&
                                                    guide.step ==
                                                        AshaGuideStep.firstSession) {
                                                  await guide.next();
                                                }
                                              },
                                        icon: Icon(monitoring
                                            ? Icons.check
                                            : Icons.play_arrow),
                                        label: Text(
                                            monitoring ? 'Continue' : 'Start'),
                                      ),
                                    );
                                  }
                                  return Switch(
                                    value: monitoring,
                                    onChanged:
                                        _busy ? null : _toggleMonitoring,
                                  );
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            _monitorStatus.message,
                            style: const TextStyle(color: Color(0xFFC9D9D5)),
                          ),
                          const SizedBox(height: 14),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _StatusChip(
                                icon: Icons.face,
                                text: _monitorStatus.faceDetected
                                    ? 'Face detected'
                                    : 'Searching for face',
                              ),
                              _StatusChip(
                                icon: Icons.remove_red_eye_outlined,
                                text: _eyeLabel(_monitorStatus),
                              ),
                              if (_monitorStatus.lipTremorDetected)
                                const _StatusChip(
                                  icon: Icons.graphic_eq,
                                  text: 'Lip micro-movement tracking',
                                ),
                              if (_lastSignal != null)
                                _StatusChip(
                                  icon: Icons.bolt,
                                  text: _lastSignal!.kind.displayName,
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Camera breathing estimate (not a medical measurement)',
                            style: TextStyle(
                              color: Color(0xFFA6E3D9),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            _monitorStatus.breathingStatus,
                            style: const TextStyle(
                              color: Color(0xFFC9D9D5),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Processed entirely locally on device. Calibrated gestures trigger voice playback, wheelchair screen captions, and caregiver alerts.',
                            style: TextStyle(
                              color: Color(0xFF9FB4AF),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 12),
                          const Divider(color: Color(0x33FFFFFF)),
                          const SizedBox(height: 6),
                          const Text(
                            'Quick Signal Test (Tap to Trigger):',
                            style: TextStyle(
                              color: Color(0xFFA6E3D9),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _TestSignalButton(
                                  label: 'Blink',
                                  icon: Icons.visibility_outlined,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(PatientSignalKind.blink),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Rapid Blinks',
                                  icon: Icons.electric_bolt,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.rapidBlink),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Slow Blink',
                                  icon: Icons.nights_stay,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.slowBlink),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Smile',
                                  icon: Icons.sentiment_satisfied_alt,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(PatientSignalKind.smile),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Left Smile',
                                  icon: Icons.mood,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.smileLeft),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Right Smile',
                                  icon: Icons.mood,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.smileRight),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Mouth Open',
                                  icon: Icons.face,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.mouthOpen),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Eyebrows Up',
                                  icon: Icons.arrow_upward,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.eyebrowsUp),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Raise Hand',
                                  icon: Icons.pan_tool,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.handRaised),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Open Palm',
                                  icon: Icons.front_hand,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.handOpenPalm),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Periocular micro-movement',
                                  icon: Icons.remove_red_eye,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.eyeTremor),
                                ),
                                const SizedBox(width: 6),
                                _TestSignalButton(
                                  label: 'Lip micro-movement',
                                  icon: Icons.graphic_eq,
                                  onTap: () => widget.services.monitor
                                      .simulateSignal(
                                          PatientSignalKind.lipTremor),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _PhraseCard(
                phrases: widget.services.recognition.phrases,
                lastPhrase: _lastPhrase,
                onSpeak: widget.services.recognition.speakNow,
              ),
              const SizedBox(height: 16),
              Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: SwitchListTile(
                  value: _waterEnabled,
                  onChanged: _toggleWater,
                  secondary: const CircleAvatar(
                    backgroundColor: Color(0xFFD9F1EC),
                    child: Icon(Icons.water_drop_outlined,
                        color: Color(0xFF0B756A)),
                  ),
                  title: const Text('Gentle hydration reminder'),
                  subtitle: const Text(
                    'Asha gently reminds you hourly; drink only when safe.',
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _callCaregiver,
                  icon: const Icon(Icons.call),
                  label: const Text('Call My Caregiver',
                      style: TextStyle(fontSize: 16)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 56,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB42318),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: _requestEmergencyHelp,
                  icon: const Icon(Icons.emergency),
                  label: const Text('Emergency Help SOS',
                      style: TextStyle(fontSize: 16)),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _eyeLabel(MonitorStatus status) {
    if (status.leftEyeOpen == null || status.rightEyeOpen == null) {
      return 'Eye tracking ready';
    }
    final average = (status.leftEyeOpen! + status.rightEyeOpen!) / 2;
    return average < 0.3 ? 'Eyes closed' : 'Eyes open';
  }
}

class _PatientHeader extends StatelessWidget {
  const _PatientHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('NEUROBRIDGE ASHA • PATIENT',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF0B756A),
                  letterSpacing: 1.6,
                  fontWeight: FontWeight.w800,
                )),
        const SizedBox(height: 6),
        Text('You’re not alone.',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                )),
        const Text(
          'Asha is with you. Blink, move your eyes, smile, or use gestures to speak.',
          style: TextStyle(fontSize: 15, color: Color(0xFF4A5E59)),
        ),
      ],
    );
  }
}

class _ReassuranceCard extends StatelessWidget {
  const _ReassuranceCard({required this.online, this.onTap});

  final bool online;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xFFD9F1EC),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const Icon(Icons.favorite, color: Color(0xFF0B756A), size: 36),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('Asha is with you',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.bold,
                                )),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF0B756A),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.chat_bubble_outline,
                                  size: 12, color: Colors.white),
                              SizedBox(width: 4),
                              Text('Tap to talk',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Asha is here if you need anything. Ready for intentional gaze, expression, or gesture cues.',
                      style:
                          TextStyle(fontSize: 13.5, color: Color(0xFF134E48)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF1C3A35),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: const Color(0xFFA6E3D9)),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 13)),
        ],
      ),
    );
  }
}

class _PhraseCard extends StatelessWidget {
  const _PhraseCard({
    required this.phrases,
    required this.lastPhrase,
    required this.onSpeak,
  });

  final List<CalibratedPhrase> phrases;
  final CalibratedPhrase? lastPhrase;
  final Future<void> Function(CalibratedPhrase) onSpeak;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.record_voice_over, color: Color(0xFF0B756A)),
                const SizedBox(width: 8),
                Text('My Voice & Quick Phrases',
                    style: Theme.of(context).textTheme.titleLarge),
              ],
            ),
            const SizedBox(height: 6),
            Text(
                lastPhrase == null
                    ? 'Trigger gestures or tap below to speak immediately.'
                    : 'Last spoken: “${lastPhrase!.phrase}”',
                style: const TextStyle(color: Color(0xFF556E68))),
            const SizedBox(height: 14),
            if (phrases.isEmpty)
              const Text(
                  'A caregiver can calibrate and add phrases in the Caregiver tab.')
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: phrases
                    .map((phrase) => FilledButton.tonal(
                          onPressed: () => onSpeak(phrase),
                          child: Text(phrase.phrase),
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }
}

class _TestSignalButton extends StatelessWidget {
  const _TestSignalButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1D3B36),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: const Color(0xFFA6E3D9)),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  color: Color(0xFFE3F2EE),
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
