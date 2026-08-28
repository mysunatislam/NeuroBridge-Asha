import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:fingerspeak_mobile/ui/hand_calibration_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ControlledMonitor extends NoOpPatientSignalMonitor {
  final stopCompleter = Completer<void>();
  int stopCalls = 0;
  int startCalls = 0;

  @override
  Future<void> stop() {
    stopCalls += 1;
    return stopCompleter.future;
  }

  @override
  Future<void> start() async {
    startCalls += 1;
  }
}

void main() {
  testWidgets('hand studio waits for camera release and orders restart',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final monitor = _ControlledMonitor();
    final services = await MobileServices.forTest(monitor: monitor);

    await tester.pumpWidget(
      MaterialApp(home: HandCalibrationPage(services: services)),
    );

    expect(monitor.stopCalls, 1);
    expect(find.text('Preparing camera for hand tracking…'), findsOneWidget);

    // Disposing before stop completes must not race start() against the release.
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(monitor.startCalls, 0);

    monitor.stopCompleter.complete();
    await tester.pump();
    await tester.pump();
    expect(monitor.startCalls, 1);

    final disposing = services.dispose();
    // PatientVoiceService uses bounded real-plugin teardown timeouts. Advance
    // the widget test's fake clock so those safeguards can complete.
    await tester.pump(const Duration(seconds: 1));
    await disposing;
  });
}
