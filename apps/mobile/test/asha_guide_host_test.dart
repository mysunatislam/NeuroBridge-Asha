import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('guide is accessible, highlights a target, and replays narration',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final guide = AshaGuideService(preferences);
    final narration = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: AshaGuideHost(
          service: guide,
          onNarrate: narration.add,
          child: Scaffold(
            body: Center(
              child: AshaGuideTarget(
                step: AshaGuideStep.profile,
                child: FilledButton(
                  onPressed: () {},
                  child: const Text('Open patient profile'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('asha-guide-card')), findsOneWidget);
    expect(find.text('Welcome to Asha Guide'), findsOneWidget);
    expect(narration, [AshaGuideStep.welcome.message]);

    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('Next'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    expect(find.text('Create the patient profile'), findsOneWidget);
    expect(find.byKey(const ValueKey('asha-guide-pointer')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('asha-guide-missing-target')),
      findsNothing,
    );

    await tester.tap(find.byTooltip('Replay Asha voice'));
    await tester.pump();
    expect(narration.last, AshaGuideStep.profile.message);
    expect(narration.length, 4);

    final semantics = tester.getSemantics(
      find.byKey(const ValueKey('asha-guide-card')),
    );
    expect(semantics.label, contains('Step 3 of 6'));
  });

  testWidgets('missing target has a safe fallback and reduced motion',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final guide = AshaGuideService(preferences);
    await guide.next();

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: AshaGuideHost(
            service: guide,
            child: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey('asha-guide-missing-target')),
      findsOneWidget,
    );
    final positioned = tester.widget<AnimatedPositioned>(
      find.byKey(const ValueKey('asha-guide-pointer-position')),
    );
    expect(positioned.duration, Duration.zero);
  });

  testWidgets('nonmodal visual overlay does not absorb emergency controls',
      (tester) async {
    final preferences = await SharedPreferences.getInstance();
    final guide = AshaGuideService(preferences);
    var emergencyTaps = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: AshaGuideHost(
          service: guide,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SafeArea(
                child: FilledButton(
                  key: const ValueKey('emergency-control'),
                  onPressed: () => emergencyTaps++,
                  child: const Text('Emergency Help'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('emergency-control')));
    await tester.pump();
    expect(emergencyTaps, 1);
  });

  testWidgets(
      'phone layout supports large text without overflow or blocked safety',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final preferences = await SharedPreferences.getInstance();
    final guide = AshaGuideService(preferences);
    await guide.next();
    await guide.next();
    var emergencyTaps = 0;
    var narrationCount = 0;

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 640),
          textScaler: TextScaler.linear(2),
          disableAnimations: true,
        ),
        child: AshaGuideHost(
          service: guide,
          onNarrate: (_) => narrationCount++,
          child: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: FilledButton(
                key: const ValueKey('phone-emergency-control'),
                onPressed: () => emergencyTaps++,
                child: const Text('Emergency'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Skip guide').hitTestable(), findsOneWidget);
    expect(find.text('Back').hitTestable(), findsOneWidget);
    expect(find.text('Next').hitTestable(), findsOneWidget);
    expect(find.byTooltip('Replay Asha voice').hitTestable(), findsOneWidget);
    await tester.tap(find.byTooltip('Replay Asha voice'));
    await tester.tap(find.byKey(const ValueKey('phone-emergency-control')));
    await tester.pump();
    expect(narrationCount, 2);
    expect(emergencyTaps, 1);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Skip guide'));
    await tester.pump();
    expect(guide.isActive, isFalse);
  });
}
