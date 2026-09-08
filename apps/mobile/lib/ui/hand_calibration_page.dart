// hand_calibration_page.dart
// FingerSpeak 3D MediaPipe Hand Gesture Calibration & Recognition Studio.
// Embeds the complete MediaPipe Tasks Vision + TensorFlow.js 21-point tracking,
// BiGRU neural training, and DTW gesture classifier from fingerspeak.html.

import 'dart:async';

import 'package:flutter/material.dart';
import '../core/mobile_services.dart';
import '../models/patient_access_method.dart';
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
    // M-7: A 10-second timeout is applied in FutureBuilder to avoid permanent loading.
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
          content: Text('Asha Hand Model: $message'),
          backgroundColor: const Color(0xFF2E7D74),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPatientMode = widget.mode == HandStudioMode.patientExecution;
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
                isPatientMode
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
      // C-6: Large accessible "Return to Dashboard" FAB for patients in execution mode.
      // Face/eye/switch users cannot reach the standard AppBar back arrow.
      floatingActionButton: isPatientMode
          ? Semantics(
              label: 'Return to Dashboard',
              button: true,
              child: FloatingActionButton.extended(
                onPressed: () => Navigator.of(context).pop(),
                backgroundColor: const Color(0xFF0D9488),
                foregroundColor: Colors.white,
                icon: const Icon(Icons.arrow_back),
                label: const Text(
                  'Return to Dashboard',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            )
          : null,
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: FutureBuilder<void>(
        // M-7: 10-second timeout prevents permanent spinner if camera release hangs.
        future: _cameraRelease.timeout(
          const Duration(seconds: 10),
          onTimeout: () => throw TimeoutException(
            'Camera took too long to release.',
          ),
        ),
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
                      'Camera took too long to release. Tap Retry to try again.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _retryCameraRelease,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Retry'),
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
            patientExecutionMode: isPatientMode,
          );
        },
      ),
    );
  }
}
