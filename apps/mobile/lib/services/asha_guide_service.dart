import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Ordered stages in the first-run NeuroBridge Asha walkthrough.
enum AshaGuideStep {
  welcome,
  role,
  profile,
  calibration,
  firstSession,
  report,
  complete,
}

extension AshaGuideStepContent on AshaGuideStep {
  String get title => switch (this) {
        AshaGuideStep.welcome => 'Welcome to Asha Guide',
        AshaGuideStep.role => 'Choose who is using this device',
        AshaGuideStep.profile => 'Create the patient profile',
        AshaGuideStep.calibration => 'Calibrate comfortable movements',
        AshaGuideStep.firstSession => 'Start the first session',
        AshaGuideStep.report => 'Review session progress',
        AshaGuideStep.complete => 'Setup complete',
      };

  String get message => switch (this) {
        AshaGuideStep.welcome =>
          'Hi, I will help you set up NeuroBridge. Follow my pointer.',
        AshaGuideStep.role =>
          'Choose Patient or Caregiver, then open the dashboard. We will set up the patient together.',
        AshaGuideStep.profile =>
          'First, let’s create the patient profile with name, age, condition, and caregiver details.',
        AshaGuideStep.calibration =>
          'Now we will calibrate your camera. Sit comfortably and follow the instructions.',
        AshaGuideStep.firstSession =>
          'Press here when you are ready to begin the communication session.',
        AshaGuideStep.report =>
          'Finally, review session quality, speech triggers, and safety alerts.',
        AshaGuideStep.complete =>
          'Asha Guide is complete. You can replay it anytime from Setup.',
      };

  bool get expectsTarget => switch (this) {
        AshaGuideStep.welcome || AshaGuideStep.complete => false,
        _ => true,
      };
}

/// Persists and advances the versioned Asha Guide state machine.
///
/// A completed guide stays hidden for the same [guideVersion]. Increasing the
/// version presents a newly revised guide without deleting older preferences.
class AshaGuideService extends ChangeNotifier {
  AshaGuideService(
    this._preferences, {
    this.guideVersion = currentGuideVersion,
  }) : assert(guideVersion > 0) {
    _step = _loadInitialStep();
  }

  static const int currentGuideVersion = 1;
  static const String _completedVersionKey = 'asha_guide.completed_version';

  final SharedPreferences _preferences;
  final int guideVersion;
  late AshaGuideStep _step;
  bool _roleSelected = false;

  String get _stepKey => 'asha_guide.v$guideVersion.current_step';

  AshaGuideStep get step => _step;
  bool get isActive => _step != AshaGuideStep.complete;
  int get visibleStepNumber => isActive
      ? _step.index +
          1 -
          (_roleSelected && _step.index > AshaGuideStep.role.index ? 1 : 0)
      : visibleStepCount;
  int get visibleStepCount =>
      AshaGuideStep.complete.index - (_roleSelected ? 1 : 0);

  /// Role selection is owned by the app's role repository. Once it is saved,
  /// omit that step in both directions so Back cannot loop at the profile.
  Future<void> setRoleSelected(bool selected) async {
    if (_roleSelected == selected) return;
    _roleSelected = selected;
    if (selected && _step == AshaGuideStep.role) {
      await _moveTo(AshaGuideStep.profile);
    } else {
      notifyListeners();
    }
  }

  AshaGuideStep _loadInitialStep() {
    final completedVersion = _preferences.getInt(_completedVersionKey) ?? 0;
    if (completedVersion >= guideVersion) return AshaGuideStep.complete;

    final storedName = _preferences.getString(_stepKey);
    if (storedName == null) return AshaGuideStep.welcome;
    return AshaGuideStep.values.firstWhere(
      (candidate) =>
          candidate != AshaGuideStep.complete && candidate.name == storedName,
      orElse: () => AshaGuideStep.welcome,
    );
  }

  Future<void> next() async {
    if (!isActive) return;
    var nextIndex = _step.index + 1;
    if (_roleSelected && nextIndex == AshaGuideStep.role.index) nextIndex++;
    if (nextIndex >= AshaGuideStep.complete.index) {
      await _finish();
      return;
    }
    await _moveTo(AshaGuideStep.values[nextIndex]);
  }

  Future<void> back() async {
    if (!isActive || _step == AshaGuideStep.welcome) return;
    var previousIndex = _step.index - 1;
    if (_roleSelected && previousIndex == AshaGuideStep.role.index) {
      previousIndex--;
    }
    await _moveTo(AshaGuideStep.values[previousIndex]);
  }

  /// Dismisses the guide for this version. It can still be replayed later.
  Future<void> skip() => _finish();

  /// Replays from the welcome step and persists the restart so an interrupted
  /// replay resumes instead of disappearing on the next app launch.
  Future<void> restart() async {
    _step = AshaGuideStep.welcome;
    notifyListeners();
    await _preferences.setInt(_completedVersionKey, guideVersion - 1);
    await _preferences.setString(_stepKey, _step.name);
  }

  Future<void> _moveTo(AshaGuideStep nextStep) async {
    if (nextStep == _step || nextStep == AshaGuideStep.complete) return;
    _step = nextStep;
    notifyListeners();
    await _preferences.setString(_stepKey, nextStep.name);
  }

  Future<void> _finish() async {
    if (_step == AshaGuideStep.complete) return;
    _step = AshaGuideStep.complete;
    notifyListeners();
    await _preferences.setInt(_completedVersionKey, guideVersion);
    await _preferences.remove(_stepKey);
  }
}
