// intent_calibration_page.dart
// First-time patient calibration: five 30-second recordings that produce
// patient_profile.json (normal blinking, normal facial movement, intentional
// gestures, random movement, rest). The camera monitor keeps running; no
// command is executed while a phase is recording.

import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/intent/intent_schema.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class IntentCalibrationPage extends StatefulWidget {
  const IntentCalibrationPage({required this.services, super.key});

  final MobileServices services;

  @override
  State<IntentCalibrationPage> createState() => _IntentCalibrationPageState();
}

class _PhaseSpec {
  const _PhaseSpec(this.id, this.title, this.instruction, this.icon);
  final String id;
  final String title;
  final String instruction;
  final IconData icon;
}

const List<_PhaseSpec> _phases = [
  _PhaseSpec(
    CalibrationPhase.normalBlinking,
    'Normal blinking',
    'Look at the camera and blink the way you always do. Nothing to perform.',
    Icons.remove_red_eye_outlined,
  ),
  _PhaseSpec(
    CalibrationPhase.normalFacialMovement,
    'Normal facial movement',
    'Move your face naturally: small smiles, mouth movements, glance around.',
    Icons.face_retouching_natural,
  ),
  _PhaseSpec(
    CalibrationPhase.intentionalGestures,
    'Your command gestures',
    'Perform your commands deliberately, one at a time: triple blink, hold your mouth open, raise your eyebrows, turn your head, raise a hand if you can.',
    Icons.touch_app_outlined,
  ),
  _PhaseSpec(
    CalibrationPhase.randomMovement,
    'Random movement',
    'Move without meaning: shift, glance, wiggle. This teaches Asha what is NOT a command.',
    Icons.shuffle,
  ),
  _PhaseSpec(
    CalibrationPhase.restState,
    'Rest',
    'Relax your face and rest quietly.',
    Icons.self_improvement,
  ),
];

class _IntentCalibrationPageState extends State<IntentCalibrationPage> {
  int _index = 0;
  Timer? _ticker;
  bool _recording = false;
  bool _saving = false;
  bool _monitorStartedHere = false;
  String? _message;
  final Set<String> _completed = {};

  @override
  void initState() {
    super.initState();
    final services = widget.services;
    services.recognition.beginCalibrationSession();
    services.intentRecognition.beginCalibration(
      services.intentRecognition.profile.isCalibrated
          ? services.intentRecognition.profile.patientId
          : 'patient-${DateTime.now().millisecondsSinceEpoch}',
    );
    if (services.monitor.currentStatus.lifecycle != MonitorLifecycle.active) {
      _monitorStartedHere = true;
      unawaited(services.monitor.start());
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    final services = widget.services;
    services.intentRecognition.stopCalibrationPhase();
    services.recognition.endCalibrationSession();
    if (_monitorStartedHere) unawaited(services.monitor.stop());
    super.dispose();
  }

  _PhaseSpec get _phase => _phases[_index];

  void _startPhase() {
    final intent = widget.services.intentRecognition;
    intent.startCalibrationPhase(_phase.id);
    unawaited(widget.services.voice.speakSystemPrompt('${_phase.title}. ${_phase.instruction}'));
    setState(() {
      _recording = true;
      _message = null;
    });
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(milliseconds: 200), (_) {
      if (!mounted) return;
      final progress = intent.calibrationProgress(_phase.id);
      if (progress >= 1.0) {
        _stopPhase(completed: true);
      } else {
        setState(() {});
      }
    });
  }

  void _stopPhase({required bool completed}) {
    _ticker?.cancel();
    final intent = widget.services.intentRecognition;
    final seconds = intent.calibrationSession?.recordings[_phase.id]?.seconds ?? 0.0;
    intent.stopCalibrationPhase();
    setState(() {
      _recording = false;
      if (completed || seconds >= 10.0) {
        _completed.add(_phase.id);
        _message = '${_phase.title} recorded (${seconds.toStringAsFixed(0)} s).';
        unawaited(widget.services.voice.speakSystemPrompt('Recorded. Thank you.'));
      } else {
        _message = 'Stopped early. At least 10 seconds with your face in view are needed.';
      }
    });
  }

  Future<void> _finish() async {
    setState(() => _saving = true);
    try {
      final profile = await widget.services.intentRecognition.finishCalibration();
      if (!mounted) return;
      final blinkRate = (profile.blink['rate_per_min'] ?? 0).toStringAsFixed(0);
      final separability = ((profile.gestureThresholds['separability'] as num?) ?? 0).toDouble();
      unawaited(widget.services.voice
          .speakSystemPrompt('Calibration saved. Asha now knows your normal movement.'));
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Patient profile saved'),
          content: Text(
            'Blink rate: $blinkRate per minute\n'
            'Command distinctness: ${(separability * 100).round()} %\n\n'
            'Commands now need a full movement pattern that matches your own '
            'calibration before Asha acts. Below 70 % confidence nothing happens; '
            'between 70 and 90 % Asha asks you to confirm.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
          ],
        ),
      );
      if (mounted) Navigator.of(context).pop(true);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = 'Could not build the profile: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _exportRecordings() async {
    final json = widget.services.intentRecognition.exportCalibrationRecordings();
    if (json == null) return;
    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('Calibration recordings copied as JSON (for retraining with the Python toolkit).'),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final intent = widget.services.intentRecognition;
    final status = widget.services.monitor.currentStatus;
    final progress = intent.calibrationProgress(_phase.id);
    final allDone = _completed.length == _phases.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Teach Asha your movements')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(
                    status.faceDetected ? Icons.face : Icons.face_retouching_off,
                    color: status.faceDetected ? const Color(0xFF0D9488) : const Color(0xFF64748B),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(status.message)),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Step ${_index + 1} of ${_phases.length}', style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < _phases.length; i++)
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    height: 6,
                    decoration: BoxDecoration(
                      color: _completed.contains(_phases[i].id)
                          ? const Color(0xFF0D9488)
                          : i == _index
                              ? const Color(0xFFD97706)
                              : const Color(0xFFE2E8F0),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(_phase.icon, size: 32, color: const Color(0xFF0D9488)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(_phase.title, style: Theme.of(context).textTheme.titleLarge),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(_phase.instruction, style: const TextStyle(fontSize: 16, height: 1.4)),
                  const SizedBox(height: 20),
                  LinearProgressIndicator(
                    value: progress,
                    minHeight: 10,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _recording
                        ? 'Recording ${(progress * CalibrationPhase.seconds).toStringAsFixed(0)} / ${CalibrationPhase.seconds.toStringAsFixed(0)} s'
                        : _completed.contains(_phase.id)
                            ? 'Recorded'
                            : '${CalibrationPhase.seconds.toStringAsFixed(0)} seconds',
                    style: const TextStyle(color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _saving
                              ? null
                              : _recording
                                  ? () => _stopPhase(completed: false)
                                  : _startPhase,
                          icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
                          label: Text(_recording ? 'Stop early' : (_completed.contains(_phase.id) ? 'Record again' : 'Start recording')),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Text(_message!, style: const TextStyle(color: Color(0xFF334155))),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              OutlinedButton(
                onPressed: _index > 0 && !_recording ? () => setState(() => _index--) : null,
                child: const Text('Back'),
              ),
              const Spacer(),
              if (_index < _phases.length - 1)
                FilledButton(
                  onPressed: _recording ? null : () => setState(() => _index++),
                  child: const Text('Next'),
                )
              else
                FilledButton.icon(
                  onPressed: allDone && !_recording && !_saving ? _finish : null,
                  icon: _saving
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.check),
                  label: const Text('Save profile'),
                ),
            ],
          ),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: _completed.isEmpty ? null : _exportRecordings,
            icon: const Icon(Icons.copy_all_outlined),
            label: const Text('Copy recordings for retraining'),
          ),
          const SizedBox(height: 8),
          const Text(
            'All processing stays on this device. The recordings contain movement '
            'measurements only, never camera images.',
            style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
          ),
        ],
      ),
    );
  }
}
