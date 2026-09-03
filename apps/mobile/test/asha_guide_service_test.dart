import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('guide advances, goes back, and resumes an interrupted step', () async {
    final preferences = await SharedPreferences.getInstance();
    final guide = AshaGuideService(preferences);

    expect(guide.step, AshaGuideStep.welcome);
    expect(guide.isActive, isTrue);

    await guide.next();
    expect(guide.step, AshaGuideStep.role);
    await guide.next();
    await guide.next();
    expect(guide.step, AshaGuideStep.calibration);

    await guide.back();
    expect(guide.step, AshaGuideStep.profile);

    final restored = AshaGuideService(preferences);
    expect(restored.step, AshaGuideStep.profile);
    expect(restored.isActive, isTrue);
  });

  test('skip hides this version and restart makes it resumable', () async {
    final preferences = await SharedPreferences.getInstance();
    final guide = AshaGuideService(preferences);

    await guide.skip();
    expect(guide.step, AshaGuideStep.complete);
    expect(AshaGuideService(preferences).isActive, isFalse);

    await guide.restart();
    expect(guide.step, AshaGuideStep.welcome);
    expect(guide.isActive, isTrue);

    await guide.next();
    expect(AshaGuideService(preferences).step, AshaGuideStep.role);
  });

  test('saved role is skipped in both directions without a Back loop',
      () async {
    final guide = AshaGuideService(await SharedPreferences.getInstance());
    await guide.next();
    await guide.setRoleSelected(true);
    expect(guide.step, AshaGuideStep.profile);
    expect(guide.visibleStepNumber, 2);
    expect(guide.visibleStepCount, 5);
    await guide.back();
    expect(guide.step, AshaGuideStep.welcome);
    await guide.next();
    expect(guide.step, AshaGuideStep.profile);
  });

  test('completion is versioned so a newer walkthrough can run', () async {
    final preferences = await SharedPreferences.getInstance();
    final guideV1 = AshaGuideService(preferences, guideVersion: 1);

    for (var i = 0; i < guideV1.visibleStepCount; i++) {
      await guideV1.next();
    }
    expect(guideV1.isActive, isFalse);
    expect(AshaGuideService(preferences, guideVersion: 1).isActive, isFalse);

    final guideV2 = AshaGuideService(preferences, guideVersion: 2);
    expect(guideV2.isActive, isTrue);
    expect(guideV2.step, AshaGuideStep.welcome);
  });
}
