// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:async';
import 'dart:html' as html;
import 'dart:js' as js;
import '../models/patient_signal.dart';

class WebFaceBridge {
  final _statuses = StreamController<MonitorStatus>.broadcast();
  final _signals = StreamController<PatientSignal>.broadcast();
  StreamSubscription<html.MessageEvent>? _sub;

  Stream<MonitorStatus> get statuses => _statuses.stream;
  Stream<PatientSignal> get signals => _signals.stream;

  void start() {
    _sub ??= html.window.onMessage.listen((event) {
      final raw = event.data;
      if (raw is! Map) return;

      final type = raw['type'];
      if (type == 'neurobridge_face_status') {
        final faceDetected = raw['faceDetected'] == true;
        final leftEye = (raw['leftEyeOpen'] as num?)?.toDouble();
        final rightEye = (raw['rightEyeOpen'] as num?)?.toDouble();
        final smile = (raw['smileProbability'] as num?)?.toDouble();
        final yaw = (raw['headYaw'] as num?)?.toDouble();
        final pitch = (raw['headPitch'] as num?)?.toDouble();
        final eyebrow = (raw['eyebrowDistance'] as num?)?.toDouble();
        final mouth = (raw['mouthDistance'] as num?)?.toDouble();

        _statuses.add(MonitorStatus(
          lifecycle: MonitorLifecycle.active,
          message: faceDetected
              ? 'Tracking patient face (MediaPipe Web Vision)'
              : (raw['message'] as String? ?? 'Searching for face…'),
          faceDetected: faceDetected,
          observedAt: DateTime.now(),
          leftEyeOpen: leftEye,
          rightEyeOpen: rightEye,
          smileProbability: smile,
          headYaw: yaw,
          headPitch: pitch,
          eyebrowDistance: eyebrow,
          mouthDistance: mouth,
        ));
      } else if (type == 'neurobridge_patient_signal') {
        final kindStr = raw['kind'] as String?;
        final confidence = (raw['confidence'] as num?)?.toDouble() ?? 0.95;
        final intent = raw['intent'] as String?;
        final label = raw['label'] as String?;
        if (kindStr == null) return;

        final kind = PatientSignalKind.values.firstWhere(
          (k) => k.name == kindStr,
          orElse: () => PatientSignalKind.blink,
        );

        _signals.add(PatientSignal(
          kind: kind,
          confidence: confidence,
          observedAt: DateTime.now(),
          sourceLabel: 'web_face',
          metadata: {
            if (intent != null) 'intent': intent,
            if (label != null) 'label': label,
          },
        ));
      }
    });

    try {
      if (js.context.hasProperty('NeuroBridgeFace')) {
        js.context['NeuroBridgeFace'].callMethod('start');
      }
    } catch (_) {}
  }

  void stop() {
    try {
      if (js.context.hasProperty('NeuroBridgeFace')) {
        js.context['NeuroBridgeFace'].callMethod('stop');
      }
    } catch (_) {}
  }

  void triggerGesture(String gesture) {
    try {
      html.window.postMessage({
        'type': 'neurobridge_trigger_gesture',
        'gesture': gesture,
      }, '*');
    } catch (_) {}
  }

  void resetCalibration() {
    try {
      html.window.postMessage({
        'type': 'neurobridge_reset_calibration',
      }, '*');
    } catch (_) {}
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _statuses.close();
    _signals.close();
  }
}
