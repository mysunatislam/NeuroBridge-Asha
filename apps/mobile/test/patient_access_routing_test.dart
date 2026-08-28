import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_access_method.dart';
import 'package:fingerspeak_mobile/services/patient_signal_monitor.dart';
import 'package:fingerspeak_mobile/ui/patient_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TrackingMonitor extends NoOpPatientSignalMonitor {
  _TrackingMonitor({this.holdSecondStop = false});

  final bool holdSecondStop;
  final secondStop = Completer<void>();
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<void> start() async {
    startCalls += 1;
  }

  @override
  Future<void> stop() {
    stopCalls += 1;
    if (holdSecondStop && stopCalls >= 2) return secondStop.future;
    return Future.value();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('inactive patient tab does not prompt or start a camera',
      (tester) async {
    final monitor = _TrackingMonitor();
    final services = await MobileServices.forTest(monitor: monitor);

    await tester.pumpWidget(
      MaterialApp(
        home: PatientPage(services: services, isActive: false),
      ),
    );
    await tester.pump();

    expect(
      find.text('Can the patient intentionally move their fingers?'),
      findsNothing,
    );
    expect(monitor.startCalls, 0);
    expect(monitor.stopCalls, 0);

    await tester.pumpWidget(
      MaterialApp(
        home: PatientPage(services: services, isActive: true),
      ),
    );
    await tester.pump();

    expect(
      find.text('Can the patient intentionally move their fingers?'),
      findsOneWidget,
    );
    await tester.tap(find.text('No — use face & eyes'));
    await tester.pump();
    await tester.pump();

    expect(monitor.startCalls, 1);
    expect(
      services.patientAccessMethodRepository.load(),
      PatientAccessMethod.faceEyesAndHead,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: PatientPage(services: services, isActive: false),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(monitor.stopCalls, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await monitor.dispose();
  });

  testWidgets('finger capability routes to patient hand execution mode',
      (tester) async {
    final monitor = _TrackingMonitor(holdSecondStop: true);
    final services = await MobileServices.forTest(monitor: monitor);

    await tester.pumpWidget(
      MaterialApp(home: PatientPage(services: services)),
    );
    await tester.pump();
    await tester.tap(find.text('Yes — use fingers'));
    await tester.pump();
    await tester.pump();

    expect(
      services.patientAccessMethodRepository.load(),
      PatientAccessMethod.handGestures,
    );
    expect(monitor.startCalls, 0);
    expect(find.text('NeuroBridge Asha Hand Communicator'), findsOneWidget);
    expect(find.text('Preparing camera for hand tracking…'), findsOneWidget);

    Navigator.of(
      tester.element(find.text('NeuroBridge Asha Hand Communicator')),
    ).pop();
    await tester.pumpAndSettle();
    monitor.secondStop.complete();
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await monitor.dispose();
  });
}
