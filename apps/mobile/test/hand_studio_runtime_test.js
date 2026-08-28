const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const {
  createCalibrationState,
  createStorageAdapter,
  createPresenceTracker,
  describeTimedFrames,
  resampleSequence,
} = require('../assets/web/fingerspeak_hand_runtime.js');

function frame(t, value) {
  return { t, feat: [value, value * 2] };
}

test('hand presence ignores brief MediaPipe misses', () => {
  const tracker = createPresenceTracker({ lostGraceMs: 350 });

  assert.deepEqual(tracker.seen(100), {
    present: true,
    changed: true,
    lastSeenAt: 100,
  });
  assert.equal(tracker.missed(449).present, true);
  assert.deepEqual(tracker.seen(450), {
    present: true,
    changed: false,
    lastSeenAt: 450,
  });
  assert.equal(tracker.missed(799).present, true);

  const lost = tracker.missed(800);
  assert.equal(lost.present, false);
  assert.equal(lost.changed, true);
});

test('visible landmarks survive intermittent and duplicate empty callbacks', () => {
  const state = createCalibrationState({ lostGraceMs: 700 });
  state.setTrackingReady(true);

  let current = state.updateDetection(true, 100);
  assert.equal(current.handPresent, true);
  assert.equal(current.canManualRecord, true);
  assert.equal(current.canStartWizard, true);

  current = state.updateDetection(false, 140);
  assert.equal(current.handPresent, true);
  current = state.updateDetection(false, 140);
  assert.equal(current.handPresent, true);
  current = state.updateDetection(false, 500);
  assert.equal(current.handPresent, true);

  current = state.updateDetection(true, 600);
  assert.equal(current.handPresent, true);
  current = state.updateDetection(false, 200);
  assert.equal(current.accepted, false);
  assert.equal(current.handPresent, true);

  current = state.updateDetection(false, 1299);
  assert.equal(current.handPresent, true);
  current = state.updateDetection(false, 1300);
  assert.equal(current.handPresent, false);
  assert.equal(current.canManualRecord, false);
  assert.equal(current.canStartWizard, false);
});

test('manual and guided calibration controls share the hand-ready gate', () => {
  const state = createCalibrationState({ lostGraceMs: 350 });

  assert.equal(state.snapshot().canManualRecord, false);
  assert.equal(state.snapshot().canStartWizard, false);
  state.setTrackingReady(true);
  assert.equal(state.snapshot().canManualRecord, false);

  state.updateDetection(true, 10);
  assert.equal(state.snapshot().canManualRecord, true);
  assert.equal(state.snapshot().canStartWizard, true);

  state.setWizardActive(true);
  assert.equal(state.snapshot().canManualRecord, false);
  assert.equal(state.snapshot().canStartWizard, false);
  state.setWizardActive(false);
  assert.equal(state.snapshot().canManualRecord, true);

  state.setTrackingReady(false);
  assert.equal(state.snapshot().canManualRecord, false);
  assert.equal(state.snapshot().canStartWizard, false);
});

test('camera lifecycle reset clears presence and accepts a fresh timestamp', () => {
  const state = createCalibrationState({ lostGraceMs: 700 });
  state.setTrackingReady(true);
  assert.equal(state.updateDetection(true, 500).handPresent, true);

  const reset = state.resetDetection();
  assert.equal(reset.handPresent, false);
  assert.equal(reset.changed, true);
  assert.equal(state.setTrackingReady(false).canManualRecord, false);

  state.setTrackingReady(true);
  const restarted = state.updateDetection(true, 10);
  assert.equal(restarted.accepted, true);
  assert.equal(restarted.handPresent, true);
  assert.equal(restarted.canManualRecord, true);
});

test('sparse Android landmark frames are interpolated without extrapolation', () => {
  const sampled = resampleSequence(
    [frame(0, 0), frame(300, 3), frame(900, 9)],
    4,
    900,
    { minCoverage: 0.6 },
  );

  assert.ok(sampled);
  assert.deepEqual(sampled.map((item) => item[0]), [0, 3, 6, 9]);
  assert.deepEqual(sampled[0], [0, 0]);
  assert.deepEqual(sampled.at(-1), [9, 18]);
});

test('capture sampling waits for meaningful temporal coverage', () => {
  assert.equal(
    resampleSequence(
      [frame(700, 7), frame(800, 8), frame(900, 9)],
      20,
      900,
      { minCoverage: 0.6 },
    ),
    null,
  );

  assert.deepEqual(
    describeTimedFrames(
      [frame(0, 0), frame(300, 3), frame(900, 9)],
      900,
    ),
    {
      frameCount: 3,
      spanMs: 900,
      temporalCoverage: 1,
      maxGapMs: 600,
    },
  );
});

test('model storage uses the persistent native bridge when available', async () => {
  const values = new Map();
  const storage = createStorageAdapter({
    nativeCall: async (request) => {
      if (request.action === 'set') {
        values.set(request.key, request.value);
        return { ok: true };
      }
      return { ok: true, value: values.get(request.key) ?? null };
    },
  });

  assert.equal(await storage.set('model', '{"weights":[1]}'), true);
  assert.deepEqual(await storage.get('model'), {
    value: '{"weights":[1]}',
  });
});

test('model storage falls back to browser localStorage', async () => {
  const values = new Map();
  const browserStorage = {
    setItem: (key, value) => values.set(key, value),
    getItem: (key) => values.get(key) ?? null,
  };
  const storage = createStorageAdapter({
    nativeCall: async () => {
      throw new Error('bridge not installed');
    },
    browserStorage,
  });

  assert.equal(await storage.set('meta', '{"version":2}'), true);
  assert.deepEqual(await storage.get('meta'), { value: '{"version":2}' });
});

test('native storage rejection is not hidden by ephemeral browser storage', async () => {
  let browserWriteCount = 0;
  const storage = createStorageAdapter({
    nativeCall: async () => ({ ok: false, error: 'value too large' }),
    browserStorage: {
      setItem: () => {
        browserWriteCount += 1;
      },
      getItem: () => 'stale-value',
    },
  });

  assert.equal(await storage.set('model', 'large-model'), false);
  assert.equal(await storage.get('model'), null);
  assert.equal(browserWriteCount, 0);
});

test('patient execution mode auto-loads before starting hand tracking', () => {
  const html = fs.readFileSync(
    path.join(__dirname, '../assets/web/fingerspeak_studio.html'),
    'utf8',
  );
  const start = html.indexOf('async function startPatientMode()');
  const end = html.indexOf('window.FingerSpeakStudio', start);
  const patientMode = html.slice(start, end);

  assert.ok(start >= 0);
  assert.match(patientMode, /await loadSavedModel\(\)/);
  assert.match(patientMode, /await startTracking\(\)/);
  assert.ok(
    patientMode.indexOf('await loadSavedModel()') <
      patientMode.indexOf('await startTracking()'),
  );
  assert.match(patientMode, /No saved hand model/);
  assert.match(patientMode, /if \(!liveMode\) liveToggle\.click\(\)/);
});

test('studio wires rendered landmarks into the shared calibration-ready gate', () => {
  const html = fs.readFileSync(
    path.join(__dirname, '../assets/web/fingerspeak_studio.html'),
    'utf8',
  );

  assert.match(html, /<script src="fingerspeak_hand_runtime\.js"><\/script>/);
  assert.match(html, /createCalibrationState/);
  assert.match(html, /HAND_LOST_GRACE_MS = 700/);

  const renderStart = html.indexOf('function renderLoop()');
  const renderEnd = html.indexOf('const HAND_CONNECTIONS', renderStart);
  const renderLoop = html.slice(renderStart, renderEnd);
  assert.ok(renderStart >= 0 && renderEnd > renderStart);
  assert.match(renderLoop, /drawLandmarks\(lm\)/);
  assert.match(renderLoop, /markHandSeen\(processedAt\)/);
  assert.match(renderLoop, /markHandMissed\(processedAt\)/);
  assert.ok(
    renderLoop.indexOf('drawLandmarks(lm)') <
      renderLoop.indexOf('markHandSeen(processedAt)'),
  );

  const manualStart = html.indexOf('async function manualRecord');
  const manualEnd = html.indexOf('// ================= guided', manualStart);
  const manualRecord = html.slice(manualStart, manualEnd);
  assert.match(manualRecord, /canManualRecord/);

  const wizardStart = html.indexOf('async function runWizard');
  const wizardEnd = html.indexOf('// ================= motion preview', wizardStart);
  const guidedWizard = html.slice(wizardStart, wizardEnd);
  assert.match(guidedWizard, /canStartWizard/);
  assert.match(guidedWizard, /setWizardActive\(true\)/);
  assert.doesNotMatch(html, /wizardStartBtn'\)\.disabled = false/);

  const captureStart = html.indexOf('async function captureBurst');
  const captureEnd = html.indexOf('function showCaptureQuality', captureStart);
  const capture = html.slice(captureStart, captureEnd);
  assert.match(capture, /CAPTURE_MAX_WAIT_MS/);
  assert.match(capture, /describeTimedFrames/);
  assert.match(capture, /CAPTURE_MIN_TEMPORAL_COVERAGE/);
});

test('studio forwards confirmed gestures and survives Android camera lifecycle', () => {
  const html = fs.readFileSync(
    path.join(__dirname, '../assets/web/fingerspeak_studio.html'),
    'utf8',
  );

  const inferenceStart = html.indexOf('function runInference');
  const inferenceEnd = html.indexOf('function handleNoHandFrame', inferenceStart);
  const inference = html.slice(inferenceStart, inferenceEnd);
  assert.match(inference, /type: 'gesture_fired'/);
  assert.match(inference, /confidence: conf/);
  assert.match(inference, /if \(!handledByHost\) speak\(gesture\.phrase\)/);

  const trainingStart = html.indexOf("document.getElementById('trainBtn')");
  const trainingEnd = html.indexOf('async function runModelComparison', trainingStart);
  const training = html.slice(trainingStart, trainingEnd);
  assert.match(training, /type: 'training_completed'/);

  assert.match(html, /function isCameraStreamLive\(\)/);
  assert.match(html, /function releaseCameraTracking/);
  assert.match(html, /calibrationState\.resetDetection\(\)/);
  assert.match(html, /document\.addEventListener\('visibilitychange'/);
  assert.match(html, /window\.addEventListener\('pagehide'/);

  const startTrackingStart = html.indexOf('async function startTracking');
  const startTrackingEnd = html.indexOf(
    "document.getElementById('startBtn').addEventListener",
    startTrackingStart,
  );
  const startTracking = html.slice(startTrackingStart, startTrackingEnd);
  assert.match(startTracking, /if \(!handLandmarker\)/);
  assert.match(startTracking, /if \(!isCameraStreamLive\(\)\)/);
});

test('studio declares the complete research telemetry event stream', () => {
  const html = fs.readFileSync(
    path.join(__dirname, '../assets/web/fingerspeak_studio.html'),
    'utf8',
  );

  const emitterStart = html.indexOf('function emitResearchEvent');
  const emitterEnd = html.indexOf('function recordInferenceTiming', emitterStart);
  const emitter = html.slice(emitterStart, emitterEnd);
  assert.ok(emitterStart >= 0 && emitterEnd > emitterStart);
  assert.match(emitter, /if \(!RESEARCH_MODE\) return false/);
  assert.match(emitter, /type: 'research_event'/);
  assert.match(emitter, /schema_version: 1/);
  assert.match(emitter, /timestamp_ms: Date\.now\(\)/);

  assert.match(html, /emitResearchEvent\('frame_stats',\s*\{/);
  assert.match(html, /emitResearchEvent\('calibration_capture',\s*\{/);

  const inferenceStart = html.indexOf('function runInference');
  const inferenceEnd = html.indexOf('function handleNoHandFrame', inferenceStart);
  const inference = html.slice(inferenceStart, inferenceEnd);
  assert.ok(inferenceStart >= 0 && inferenceEnd > inferenceStart);
  assert.match(inference, /emitResearchEvent\('prediction',\s*\{/);
  assert.match(
    inference,
    /emitResearchEvent\('gesture_fired',\s*\{[\s\S]*?activation_latency_ms\s*:/,
  );

  const trainingStart = html.indexOf("document.getElementById('trainBtn')");
  const trainingEnd = html.indexOf('async function runModelComparison', trainingStart);
  const training = html.slice(trainingStart, trainingEnd);
  assert.ok(trainingStart >= 0 && trainingEnd > trainingStart);
  assert.match(training, /emitResearchEvent\('training_completed',\s*\{/);

  const persistenceStart = html.indexOf('// ================= save / load trained model');
  const persistenceEnd = html.indexOf('// ================= intent state machine', persistenceStart);
  const persistence = html.slice(persistenceStart, persistenceEnd);
  assert.ok(persistenceStart >= 0 && persistenceEnd > persistenceStart);
  assert.match(persistence, /emitResearchEvent\('model_saved',\s*\{/);
  assert.match(persistence, /emitResearchEvent\('model_loaded',\s*\{/);
});
