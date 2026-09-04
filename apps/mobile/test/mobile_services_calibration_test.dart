import 'dart:convert';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_signal.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _SensitivityMonitor extends NoOpPatientSignalMonitor {
  Map<PatientSignalKind, double> sensitivities = {};

  @override
  void setSignalSensitivities(Map<PatientSignalKind, double> values) {
    sensitivities = Map.of(values);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('preview is temporary and saving updates the live detector map',
      () async {
    final monitor = _SensitivityMonitor();
    final services = await MobileServices.forTest(monitor: monitor);
    addTearDown(services.dispose);

    expect(monitor.sensitivities[PatientSignalKind.blink], 0.75);
    expect(monitor.sensitivities[PatientSignalKind.eyebrowsUp], 0.80);

    services.previewFaceSignalSensitivity(PatientSignalKind.eyeLookLeft, 0.94);
    expect(monitor.sensitivities[PatientSignalKind.eyeLookLeft], 0.94);
    expect(
      services.recognition.phrases.any(
        (phrase) => phrase.signal == PatientSignalKind.eyeLookLeft,
      ),
      isFalse,
    );

    services.refreshFaceSignalSensitivities();
    expect(
      monitor.sensitivities.containsKey(PatientSignalKind.eyeLookLeft),
      isFalse,
    );

    await services.saveCalibratedPhrase(const CalibratedPhrase(
      signal: PatientSignalKind.eyeLookLeft,
      key: 'left',
      phrase: 'Please turn left',
      sensitivity: 0.94,
    ));
    expect(monitor.sensitivities[PatientSignalKind.eyeLookLeft], 0.94);
    expect(services.recognition.isCustomMode, isTrue);
  });

  test('import and standard reset replace live sensitivities', () async {
    final monitor = _SensitivityMonitor();
    final services = await MobileServices.forTest(monitor: monitor);
    addTearDown(services.dispose);
    final profile = jsonEncode({
      'phrases': [
        const CalibratedPhrase(
          signal: PatientSignalKind.smileRight,
          key: 'right-smile',
          phrase: 'Thank you',
          sensitivity: 0.91,
        ).toJson(),
      ],
    });

    expect(await services.importCalibrationProfile(profile), 1);
    expect(monitor.sensitivities, {
      PatientSignalKind.smileRight: 0.91,
    });

    await services.useStandardCalibrationProfile();
    expect(services.recognition.isCustomMode, isFalse);
    expect(monitor.sensitivities[PatientSignalKind.blink], 0.75);
    expect(
      monitor.sensitivities.containsKey(PatientSignalKind.smileRight),
      isFalse,
    );
  });

  test('saved sensitivity is applied when services are recreated', () async {
    final preferences = await SharedPreferences.getInstance();
    final firstMonitor = _SensitivityMonitor();
    final first = await MobileServices.forTest(
      preferences: preferences,
      monitor: firstMonitor,
    );
    await first.saveCalibratedPhrase(const CalibratedPhrase(
      signal: PatientSignalKind.mouthOpen,
      key: 'water',
      phrase: 'Water, please',
      sensitivity: 0.96,
    ));
    await first.dispose();

    final restoredMonitor = _SensitivityMonitor();
    final restored = await MobileServices.forTest(
      preferences: preferences,
      monitor: restoredMonitor,
    );
    addTearDown(restored.dispose);

    expect(restoredMonitor.sensitivities[PatientSignalKind.mouthOpen], 0.96);
    expect(
      restored.recognition.phrases
          .singleWhere((phrase) => phrase.signal == PatientSignalKind.mouthOpen)
          .sensitivity,
      0.96,
    );
  });

  test('custom Pi WebSocket URL can be updated and validated', () async {
    final services = await MobileServices.forTest();
    addTearDown(services.dispose);

    expect(services.pi.endpoint, Uri.parse('ws://10.0.2.2:8765/v1/device/ws'));

    final customUri = Uri.parse('ws://192.168.43.50:8765/v1/device/ws');
    services.pi.updateEndpoint(customUri);
    expect(services.pi.endpoint, customUri);
  });
}
