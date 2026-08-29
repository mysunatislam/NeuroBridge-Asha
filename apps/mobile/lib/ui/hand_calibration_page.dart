// hand_calibration_page.dart
// FingerSpeak 3D MediaPipe Hand Gesture Calibration & Recognition Studio.
// Embeds the complete MediaPipe Tasks Vision + TensorFlow.js 21-point tracking,
// BiGRU neural training, and DTW gesture classifier from fingerspeak.html.

import 'dart:async';

import 'package:flutter/material.dart';
import '../core/mobile_services.dart';
import '../models/patient_access_method.dart';
import '../models/patient_signal.dart';
import 'studio_view/platform_studio.dart';

enum HandStudioMode { calibration, patientExecution }

class HandCalibrationPage extends StatefulWidget {
  const HandCalibrationPage({
    super.key,
    required this.services,
    this.mode = HandStudioMode.calibration,
  });
  final MobileServices services;
  final HandStudioMode mode;

  @override
  State<HandCalibrationPage> createState() => _HandCalibrationPageState();
}

class _HandCalibrationPageState extends State<HandCalibrationPage> {
  late Future<void> _cameraRelease;

  @override
  void initState() {
    super.initState();
    // Do not construct the WebView until the background CameraController has
    // fully released the hardware. Android & iOS otherwise race two camera clients.
    _cameraRelease = widget.services.monitor.stop();
  }

  @override
  void dispose() {
    final handMode = widget.services.patientAccessMethodRepository.load() ==
        PatientAccessMethod.handGestures;
    if (widget.mode == HandStudioMode.calibration && !handMode) {
      // Chain restart after camera release in case the page was popped quickly.
      unawaited(_resumePatientMonitor());
    }
    super.dispose();
  }

  Future<void> _resumePatientMonitor() async {
    try {
      await _cameraRelease;
    } on Object catch (error) {
      debugPrint('[MediaPipe Studio]: Camera release failed: $error');
    }
    try {
      await widget.services.monitor.start();
    } on Object catch (error) {
      debugPrint('[MediaPipe Studio]: Patient monitor restart failed: $error');
    }
  }

  void _retryCameraRelease() {
    setState(() {
      _cameraRelease = widget.services.monitor.stop();
    });
  }

  void _onGestureFired(String gesture, String phrase, double confidence) {
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.check_circle, color: Color(0xFF4FD1C5)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '$gesture: "$phrase" (${(confidence * 100).round()}%)',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF161F29),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    // Trigger Asha voice output exactly once
    if (phrase.isNotEmpty) {
      widget.services.voice.speakPhrase('gesture_$gesture', phrase);
    }
  }

  void _onHandDetected() {}

  void _onTrainingCompleted(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('TensorFlow.js Model: $message'),
          backgroundColor: const Color(0xFF2E7D74),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                gradient: const LinearGradient(
                  colors: [Color(0xFF0D9488), Color(0xFF14B8A6)],
                ),
              ),
              child:
                  const Icon(Icons.pan_tool_alt, color: Colors.white, size: 16),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.mode == HandStudioMode.patientExecution
                    ? 'NeuroBridge Asha Hand Communicator'
                    : 'NeuroBridge Asha 3D Studio',
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF0F172A),
                ),
              ),
            ),
          ],
        ),
      ),
      body: FutureBuilder<void>(
        future: _cameraRelease,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Color(0xFF0D9488)),
                  SizedBox(height: 14),
                  Text(
                    'Preparing camera for hand tracking…',
                    style: TextStyle(color: Color(0xFF64748B)),
                  ),
                ],
              ),
            );
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.videocam_off, color: Color(0xFFE86A6A)),
                    const SizedBox(height: 12),
                    const Text(
                      'Could not release the patient camera for hand tracking.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _retryCameraRelease,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              ),
            );
          }
          return buildPlatformStudio(
            context: context,
            onGestureFired: _onGestureFired,
            onHandDetected: _onHandDetected,
            onTrainingCompleted: _onTrainingCompleted,
            patientExecutionMode:
                widget.mode == HandStudioMode.patientExecution,
          );
        },
      ),
    );
  }
}
