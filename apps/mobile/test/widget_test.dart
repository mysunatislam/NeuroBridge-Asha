import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/ui/calibration_wizard_page.dart';
import 'package:fingerspeak_mobile/ui/role_selection_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
      'RoleSelectionPage renders patient and caregiver choices and triggers selection',
      (WidgetTester tester) async {
    final services = await MobileServices.forTest();
    UserRole? selected;

    await tester.pumpWidget(
      MaterialApp(
        home: RoleSelectionPage(
          services: services,
          onRoleSelected: (role) => selected = role,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Who is using this device?'), findsOneWidget);
    expect(find.text('I am a Patient'), findsOneWidget);
    expect(find.text('I am a Caregiver'), findsOneWidget);

    // Tap "I am a Patient" card
    await tester.tap(find.text('I am a Patient'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Open Patient Dashboard'), findsOneWidget);

    // Scroll to button and tap to proceed
    await tester.scrollUntilVisible(find.text('Open Patient Dashboard'), 150);
    await tester.tap(find.text('Open Patient Dashboard'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(selected, UserRole.patient);
  });

  testWidgets('CalibrationWizardPage navigates through calibration steps',
      (WidgetTester tester) async {
    final services = await MobileServices.forTest();

    await tester.pumpWidget(
      MaterialApp(
        home: CalibrationWizardPage(services: services),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Patient Signal Calibration'), findsOneWidget);
    expect(find.text('1. Resting Baseline & Camera Alignment'), findsOneWidget);

    final nextButtons = find.text('Next Step');
    expect(nextButtons, findsWidgets);
    await tester.ensureVisible(nextButtons.first);
    await tester.pumpAndSettle();
    await tester.tap(nextButtons.first);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      find.text('2. Eye, Blink & Assisted Direction Suite'),
      findsOneWidget,
    );
    expect(find.text('Deliberate Normal Blink'), findsWidgets);

    await tester.pumpWidget(const SizedBox.shrink());
    final disposing = services.dispose();
    await tester.pump(const Duration(seconds: 1));
    await disposing;
  });
}
