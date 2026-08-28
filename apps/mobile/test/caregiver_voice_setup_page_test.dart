import 'dart:convert';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/ui/caregiver_voice_setup_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('voice setup shows coverage and includes Hand Studio phrases',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(
      'hand_studio.fingerspeak_model_meta',
      jsonEncode({
        'gestures': [
          {'name': 'Rest', 'phrase': ''},
          {'name': 'Water Hand', 'phrase': 'Hand Studio water request'},
        ],
      }),
    );
    final services = await MobileServices.forTest(preferences: preferences);
    final expectedPhraseCount = services.recognition.phrases.length + 1;

    await tester.pumpWidget(
      MaterialApp(home: CaregiverVoiceSetupPage(services: services)),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Caregiver Voice Setup'), findsOneWidget);
    expect(
      find.text('0 of $expectedPhraseCount phrases recorded'),
      findsOneWidget,
    );
    expect(find.text('Start Guided Recording'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Hand Studio water request'),
      250,
    );
    expect(find.text('Hand Studio water request'), findsOneWidget);
    expect(find.text('MediaPipe Hand Studio • Water Hand'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    final disposing = services.dispose();
    await tester.pump(const Duration(seconds: 1));
    await disposing;
  });

  testWidgets('guided setup asks before applying recordings globally',
      (tester) async {
    final services = await MobileServices.forTest();

    await tester.pumpWidget(
      MaterialApp(home: CaregiverVoiceSetupPage(services: services)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Start Guided Recording'));
    await tester.pump();

    expect(
      find.text('Use the caregiver voice for patient phrases?'),
      findsOneWidget,
    );
    expect(find.text('Use Recordings First'), findsOneWidget);

    await tester.tap(find.text('Use Recordings First'));
    await tester.pumpAndSettle();

    expect(find.textContaining('GUIDED PHRASE 1 OF'), findsOneWidget);
    expect(find.text('Speak these exact words:'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    final disposing = services.dispose();
    await tester.pump(const Duration(seconds: 1));
    await disposing;
  });
}
