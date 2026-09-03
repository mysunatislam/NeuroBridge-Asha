import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/data/pi_device_client.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/caregiver_notification_service.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/calibration_wizard_page.dart';
import 'package:fingerspeak_mobile/ui/caregiver_emergency_sheet.dart';
import 'package:fingerspeak_mobile/ui/caregiver_voice_setup_page.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class CaregiverPage extends StatefulWidget {
  const CaregiverPage({required this.services, super.key});

  final MobileServices services;

  @override
  State<CaregiverPage> createState() => CaregiverPageState();
}

class CaregiverPageState extends State<CaregiverPage> {
  final _captionController = TextEditingController();
  final _patientProfileIdController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _calibrationGuideKey = GlobalKey();
  final GlobalKey _reportGuideKey = GlobalKey();
  PiConnectionState _piState = PiConnectionState.disconnected;
  PiDeviceStatus? _piStatus;
  StreamSubscription<PiConnectionState>? _piSubscription;
  StreamSubscription<PiDeviceStatus>? _statusSubscription;
  StreamSubscription<CaregiverAlert>? _alertSubscription;

  @override
  void initState() {
    super.initState();
    _piState = widget.services.pi.state;
    _piSubscription = widget.services.pi.states.listen((state) {
      if (mounted) setState(() => _piState = state);
    });
    _statusSubscription = widget.services.pi.statuses.listen((status) {
      if (mounted) setState(() => _piStatus = status);
    });
    _alertSubscription =
        widget.services.caregiverNotifications.alerts.listen((alert) {
      if (mounted) setState(() {});
    });
    widget.services.cloudAlerts.addListener(_onCloudAlertsChanged);
  }

  @override
  void dispose() {
    widget.services.cloudAlerts.removeListener(_onCloudAlertsChanged);
    unawaited(_piSubscription?.cancel());
    unawaited(_statusSubscription?.cancel());
    unawaited(_alertSubscription?.cancel());
    _captionController.dispose();
    _patientProfileIdController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> revealGuideStep(AshaGuideStep step) async {
    if (step != AshaGuideStep.calibration && step != AshaGuideStep.report) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted || !_scrollController.hasClients) return;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final key = step == AshaGuideStep.calibration
        ? _calibrationGuideKey
        : _reportGuideKey;
    var targetContext = key.currentContext;
    if (targetContext == null) {
      final position = _scrollController.position;
      final fallback = step == AshaGuideStep.report
          ? position.maxScrollExtent
          : (position.maxScrollExtent * 0.38)
              .clamp(position.minScrollExtent, position.maxScrollExtent);
      if (reduceMotion) {
        _scrollController.jumpTo(fallback);
      } else {
        await _scrollController.animateTo(
          fallback,
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
        );
      }
      if (!mounted) return;
      targetContext = key.currentContext;
    }
    if (targetContext != null && targetContext.mounted) {
      await Scrollable.ensureVisible(
        targetContext,
        duration: reduceMotion
            ? Duration.zero
            : const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
        alignment: 0.35,
      );
    }
  }

  void _onCloudAlertsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _connectCloudDashboard() async {
    final profileId = _patientProfileIdController.text.trim();
    if (profileId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a Patient Profile UUID.')),
      );
      return;
    }
    await widget.services.cloudAlerts.connectProfile(profileId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connected to patient live dashboard: $profileId'),
          backgroundColor: const Color(0xFF0B756A),
        ),
      );
    }
  }

  Future<void> _callPatient() async {
    final phone = widget.services.config.patientPhone.trim();
    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content:
              Text('Patient phone number not set. Configure in Setup tab.'),
        ),
      );
      return;
    }
    if (!await launchUrl(Uri(scheme: 'tel', path: phone)) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open phone dialer.')),
      );
    }
  }

  Future<void> _sendCaption() async {
    final text = _captionController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a message to write on display.')),
      );
      return;
    }

    // Try cloud relay if remote devices are available
    var sentViaCloud = false;
    final devices = widget.services.cloudAlerts.remoteDevices;
    if (devices.isNotEmpty) {
      try {
        await widget.services.cloudAlerts
            .sendCaptionToDevice(devices.first.id, text);
        sentViaCloud = true;
      } catch (_) {}
    }

    // Direct local Pi fallback
    if (!sentViaCloud) {
      if (_piState != PiConnectionState.connected) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Connect to wheelchair Pi in Setup or connect Patient Profile ID for cloud relay.'),
          ),
        );
        return;
      }
      try {
        widget.services.pi.sendCaption(
          text,
          language: widget.services.config.locale,
        );
      } on Object catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not write to display: $error')),
          );
        }
        return;
      }
    }

    _captionController.clear();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sentViaCloud
              ? 'Message relayed to patient display via cloud.'
              : 'Message sent directly to wheelchair display.'),
          backgroundColor: const Color(0xFF0B756A),
        ),
      );
    }
  }

  Future<void> _openCalibrationWizard() async {
    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => CalibrationWizardPage(services: widget.services),
      ),
    );
    if (!mounted) return;
    final guide = widget.services.ashaGuide;
    if (completed == true &&
        guide.isActive &&
        guide.step == AshaGuideStep.calibration) {
      await guide.next();
    }
  }

  void _openHandCalibration() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => HandCalibrationPage(services: widget.services),
      ),
    );
  }

  void _openCaregiverVoiceSetup() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CaregiverVoiceSetupPage(services: widget.services),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final alerts = widget.services.caregiverNotifications.recentAlerts;
    final phrases = widget.services.recognition.phrases;

    return ListView(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NEUROBRIDGE ASHA • CAREGIVER',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: const Color(0xFFC04B67),
                          letterSpacing: 1.6,
                          fontWeight: FontWeight.w800,
                        )),
                const SizedBox(height: 4),
                Text('Caregiver Hub',
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        )),
              ],
            ),
            IconButton.filledTonal(
              style: IconButton.styleFrom(
                backgroundColor: const Color(0xFFFECDCA),
                foregroundColor: const Color(0xFFB42318),
              ),
              icon: const Icon(Icons.emergency),
              tooltip: 'Emergency Clinical Guide',
              onPressed: () =>
                  showCaregiverEmergencySheet(context, widget.services),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // MediaPipe Hand Gesture Engine Card (from fingerspeak.html)
        Card(
          color: const Color(0xFF0F1720),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF4FD1C5), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFF2E7D74),
                  child: Icon(Icons.pan_tool_alt,
                      color: Color(0xFF4FD1C5), size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MediaPipe Hand Gesture Suite',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF4FD1C5),
                        ),
                      ),
                      Text(
                        '98-Feature 3D DTW & Prototype Calibrator',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF8CA0A8)),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF4FD1C5),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: _openHandCalibration,
                  child: const Text('Calibrate'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Emergency Guidance Banner
        Card(
          color: const Color(0xFFFFF0F2),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFFFECDCA), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFB42318),
                  child: Icon(Icons.medical_services,
                      color: Colors.white, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Asha Emergency Assistant',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          color: Color(0xFF7A150E),
                        ),
                      ),
                      Text(
                        'Instant Seizure & Choking First-Aid + 1-Tap Ambulance',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF555555)),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB42318),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  onPressed: () =>
                      showCaregiverEmergencySheet(context, widget.services),
                  child: const Text('Open'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Connect Patient Profile ID Card (Cloud Sync)
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.cloud_sync, color: Color(0xFF0B756A)),
                    const SizedBox(width: 8),
                    Text(
                      'Connect Patient Profile ID',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const Spacer(),
                    if (widget.services.cloudAlerts.currentProfileId != null)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8F6F3),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFA6E3D9)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.check_circle,
                                size: 12, color: Color(0xFF0B756A)),
                            SizedBox(width: 4),
                            Text('LIVE CONNECTED',
                                style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold,
                                    color: Color(0xFF0B756A))),
                          ],
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                const Text(
                  'Enter the patient’s profile UUID to receive real-time cloud alerts and relay display captions.',
                  style: TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _patientProfileIdController,
                        style: const TextStyle(
                            fontSize: 13, fontFamily: 'monospace'),
                        decoration: const InputDecoration(
                          hintText: 'Enter patient profile UUID…',
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 10),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: _connectCloudDashboard,
                      child: const Text('Connect'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Wheelchair Hardware Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: _piState == PiConnectionState.connected
                      ? const Color(0xFFD9F1EC)
                      : const Color(0xFFFFE8C7),
                  child: Icon(
                    _piState == PiConnectionState.connected
                        ? Icons.wifi
                        : Icons.wifi_off,
                    color: _piState == PiConnectionState.connected
                        ? const Color(0xFF0B756A)
                        : Colors.orange.shade800,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Wheelchair Unit (Pi & NoIR Cam)',
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                      ),
                      Text(_piStatusLabel()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Calibration Mode Launch Card
        Card(
          color: const Color(0xFFF3FBF9),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF9DE0D5), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(Icons.tune, color: Color(0xFF0B756A), size: 28),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Patient Signal Calibration',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF0B756A),
                            ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Calibrate custom triggers for eyes, facial muscles, lip/eye micro-movements, head motion, and hand gestures.',
                  style: TextStyle(fontSize: 14, color: Color(0xFF3B5E57)),
                ),
                const SizedBox(height: 14),
                AshaGuideTarget(
                  key: _calibrationGuideKey,
                  step: AshaGuideStep.calibration,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0B756A),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _openCalibrationWizard,
                    icon: const Icon(Icons.app_registration),
                    label: const Text(
                      'Start Step-by-Step Calibration',
                      style:
                          TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Guided Caregiver Voice Setup Card
        Card(
          color: const Color(0xFFFFF7ED),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFFF7C98B), width: 1.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.family_restroom,
                      color: Color(0xFFB54708),
                      size: 28,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Caregiver Voice Setup',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: const Color(0xFF8A3A06),
                            ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Record every calibrated and Hand Studio phrase with guided prompts, listen to each result, and choose whether caregiver recordings should be preferred across the app.',
                  style: TextStyle(fontSize: 14, color: Color(0xFF69411F)),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFFB54708),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _openCaregiverVoiceSetup,
                  icon: const Icon(Icons.multitrack_audio),
                  label: const Text(
                    'Set Up Caregiver Voice',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Write on Wheelchair Display Card
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Write to Wheelchair Display',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 4),
                const Text(
                  'Send dynamic text captions that appear prominently on the wheelchair screen.',
                  style: TextStyle(color: Color(0xFF556E68)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _captionController,
                  maxLength: 280,
                  minLines: 2,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Message for patient display',
                    hintText: 'e.g., I am bringing your lunch now',
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _PresetCaptionChip(
                      label: '“I’m on my way”',
                      onTap: () {
                        _captionController.text = 'I am on my way';
                        _sendCaption();
                      },
                    ),
                    _PresetCaptionChip(
                      label: '“Lunch is ready”',
                      onTap: () {
                        _captionController.text = 'Lunch is ready for you';
                        _sendCaption();
                      },
                    ),
                    _PresetCaptionChip(
                      label: '“Rest well”',
                      onTap: () {
                        _captionController.text =
                            'Take your time and rest well';
                        _sendCaption();
                      },
                    ),
                    _PresetCaptionChip(
                      label: '“Water is here”',
                      onTap: () {
                        _captionController.text =
                            'I am bringing some fresh water';
                        _sendCaption();
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: _sendCaption,
                    icon: const Icon(Icons.tv),
                    label: const Text('Show on Wheelchair Display'),
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 52,
                  child: OutlinedButton.icon(
                    onPressed: _callPatient,
                    icon: const Icon(Icons.call),
                    label: const Text('Call Patient Directly'),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Real-Time Patient Activity & Alert Feed
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Live Patient Alert Feed',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    if (alerts.isNotEmpty ||
                        widget.services.cloudAlerts.alerts.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          await widget.services.caregiverNotifications
                              .clearAlerts();
                          if (mounted) setState(() {});
                        },
                        child: const Text('Clear Local'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),

                // Cloud alerts (if any)
                if (widget.services.cloudAlerts.alerts.isNotEmpty) ...[
                  const Text('Cloud Sync Alerts:',
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF0B756A))),
                  const SizedBox(height: 6),
                  ...widget.services.cloudAlerts.alerts.take(5).map((ca) {
                    final isEmergency = ca.severity == 'emergency';
                    final isResolved = ca.status == 'resolved';
                    final isAck = ca.status == 'acknowledged';
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isResolved
                            ? const Color(0xFFF3F4F6)
                            : isEmergency
                                ? const Color(0xFFFFF0F2)
                                : const Color(0xFFE8F6F3),
                        border: Border.all(
                          color: isResolved
                              ? const Color(0xFFD1D5DB)
                              : isEmergency
                                  ? const Color(0xFFFECDCA)
                                  : const Color(0xFFA6E3D9),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isEmergency ? Icons.warning : Icons.cloud_queue,
                            color: isResolved
                                ? Colors.grey
                                : isEmergency
                                    ? const Color(0xFFB42318)
                                    : const Color(0xFF0B756A),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      isEmergency
                                          ? 'EMERGENCY ALERT'
                                          : 'PATIENT SPEECH',
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        color: isEmergency
                                            ? const Color(0xFFB42318)
                                            : const Color(0xFF0B756A),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: isResolved
                                            ? Colors.grey.shade300
                                            : isAck
                                                ? Colors.amber.shade200
                                                : Colors.red.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        ca.status.toUpperCase(),
                                        style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.bold,
                                            color: isResolved
                                                ? Colors.grey.shade700
                                                : isAck
                                                    ? Colors.amber.shade900
                                                    : Colors.red.shade900),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 2),
                                Text(ca.message,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600)),
                              ],
                            ),
                          ),
                          if (!isResolved) ...[
                            if (!isAck)
                              TextButton(
                                onPressed: () => widget.services.cloudAlerts
                                    .acknowledgeAlert(ca.id),
                                child: const Text('Ack',
                                    style: TextStyle(fontSize: 12)),
                              ),
                            FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                              ),
                              onPressed: () => widget.services.cloudAlerts
                                  .resolveAlert(ca.id),
                              child: const Text('Resolve',
                                  style: TextStyle(fontSize: 12)),
                            ),
                          ],
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 4),
                ],

                if (alerts.isEmpty &&
                    widget.services.cloudAlerts.alerts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                        'No patient alerts yet. New speech and signals will appear here instantly.'),
                  )
                else
                  ...alerts.take(10).map((a) {
                    final isEmergency = a.urgency == AlertUrgency.emergency;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isEmergency
                            ? const Color(0xFFFFF0F2)
                            : const Color(0xFFF6F9F8),
                        border: Border.all(
                          color: isEmergency
                              ? const Color(0xFFFECDCA)
                              : const Color(0xFFDDE7E4),
                        ),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            isEmergency
                                ? Icons.warning
                                : Icons.record_voice_over,
                            color: isEmergency
                                ? const Color(0xFFB42318)
                                : const Color(0xFF0B756A),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  a.title,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isEmergency
                                        ? const Color(0xFFB42318)
                                        : Colors.black87,
                                  ),
                                ),
                                Text(a.message),
                              ],
                            ),
                          ),
                          Text(
                            '${a.timestamp.hour.toString().padLeft(2, '0')}:${a.timestamp.minute.toString().padLeft(2, '0')}',
                            style: const TextStyle(
                                fontSize: 12, color: Colors.black54),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),

        // Active Calibrated Signals Summary
        Card(
          color: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Active Calibrated Phrases (${phrases.length})',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                if (phrases.isEmpty)
                  const Text('No phrases calibrated yet.')
                else
                  ...phrases.map((p) => ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_outline,
                            color: Color(0xFF0B756A)),
                        title: Text(p.phrase,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Text(
                            '${p.signal.displayName} • Sensitivity ${(p.sensitivity * 100).round()}%'),
                      )),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Session Quality Metrics Card
        AshaGuideTarget(
          key: _reportGuideKey,
          step: AshaGuideStep.report,
          child: ListenableBuilder(
            listenable: widget.services.sessionMetrics,
            builder: (context, _) {
              final metrics = widget.services.sessionMetrics;
              return Card(
                color: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(children: [
                        const Icon(Icons.bar_chart, color: Color(0xFF0B756A)),
                        const SizedBox(width: 8),
                        Text('Session Quality',
                            style: Theme.of(context).textTheme.titleLarge),
                        const Spacer(),
                        TextButton.icon(
                          onPressed: () {
                            widget.services.sessionMetrics.reset();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Session metrics reset.')),
                            );
                          },
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('Reset'),
                        ),
                      ]),
                      const SizedBox(height: 4),
                      const Text(
                        'Track communication effectiveness this session.',
                        style:
                            TextStyle(fontSize: 13, color: Color(0xFF556E68)),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _MetricTile(
                            icon: Icons.record_voice_over,
                            color: const Color(0xFF0B756A),
                            label: 'Phrases\nSpoken',
                            value: '${metrics.phrasesSpoken}',
                          ),
                          _MetricTile(
                            icon: Icons.error_outline,
                            color: Colors.orange,
                            label: 'False\nActivations',
                            value: '${metrics.falseActivations}',
                            onMark: () => widget.services.sessionMetrics
                                .markFalseActivation(),
                          ),
                          _MetricTile(
                            icon: Icons.visibility_off,
                            color: Colors.redAccent,
                            label: 'Missed\nGestures',
                            value: '${metrics.missedGestures}',
                            onMark: () => widget.services.sessionMetrics
                                .markMissedGesture(),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  String _piLabel(PiConnectionState state) => switch (state) {
        PiConnectionState.disconnected => 'Offline — check Setup',
        PiConnectionState.connecting => 'Connecting wirelessly…',
        PiConnectionState.authenticating => 'Authenticating pairing…',
        PiConnectionState.connected => 'Online & synced to wheelchair',
        PiConnectionState.error => 'Connection error — check Wi-Fi/USB',
      };

  String _piStatusLabel() {
    final base = _piLabel(_piState);
    final status = _piStatus;
    if (status == null || _piState != PiConnectionState.connected) return base;
    final piBattery = status.piBatteryPercent?.round();
    final chairBattery = status.wheelchairBatteryPercent?.round();
    return '$base • Cam: ${status.camera}'
        '${piBattery == null ? '' : ' • Pi: $piBattery%'}'
        '${chairBattery == null ? '' : ' • Chair: $chairBattery%'}';
  }
}

class _PresetCaptionChip extends StatelessWidget {
  const _PresetCaptionChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      backgroundColor: const Color(0xFFE8F6F3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFA6E3D9)),
      ),
      onPressed: onTap,
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    this.onMark,
  });

  final IconData icon;
  final Color color;
  final String label;
  final String value;
  final VoidCallback? onMark;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onMark,
      child: Container(
        width: 96,
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.25)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(height: 4),
            Text(
              value,
              style: TextStyle(
                  fontSize: 26, fontWeight: FontWeight.w800, color: color),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11, color: color, fontWeight: FontWeight.w600),
            ),
            if (onMark != null) ...[
              const SizedBox(height: 6),
              Text(
                'Tap to mark',
                style: TextStyle(
                    fontSize: 9, color: color.withValues(alpha: 0.65)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
