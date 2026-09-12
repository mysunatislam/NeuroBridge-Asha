// window_features.dart
// Dart port of services/intent/src/neurobridge_intent/features/window.py,
// blink.py and trajectory.py. Numerics follow NumPy semantics (population
// std, np.gradient edge handling, linear-interpolation percentiles) so the
// exported models see identical inputs on device. test/intent_parity_test.dart
// pins reference vectors produced by the Python implementation.

import 'dart:math' as math;

import 'intent_schema.dart';

/// One resampled frame: timestamp (seconds) and the 28-channel vector.
class IntentFrame {
  IntentFrame(this.tSeconds, List<double> values)
      : values = List<double>.unmodifiable(values) {
    if (values.length != kFrameFeatureCount) {
      throw ArgumentError(
          'frame needs $kFrameFeatureCount values, got ${values.length}');
    }
    for (final v in values) {
      if (!v.isFinite) throw ArgumentError('frame features must be finite');
    }
  }

  final double tSeconds;
  final List<double> values;

  double operator [](int channel) => values[channel];
}

class BlinkEvent {
  const BlinkEvent(this.startS, this.endS, this.depth, this.closingVelocity);
  final double startS;
  final double endS;
  final double depth;
  final double closingVelocity;
  double get durationMs => (endS - startS) * 1000.0;
}

/// Stateful eye-closure detector (port of BlinkDetector).
class BlinkDetector {
  BlinkDetector({
    double openEar = 0.30,
    this.closureRatio = 0.55,
    this.minDurationMs = 60.0,
    this.maxDurationMs = 700.0,
  }) : openEar = math.max(openEar, 1e-3);

  double openEar;
  final double closureRatio;
  final double minDurationMs;
  final double maxDurationMs;
  double? _closedSince;
  double _minEar = double.infinity;
  double? _lastT;
  double? _lastEar;
  double _maxVelocity = 0.0;

  double get threshold => openEar * (1.0 - closureRatio);
  bool get isClosed => _closedSince != null;

  void setOpenBaseline(double value) {
    if (value.isFinite && value > 0) openEar = value;
  }

  void reset() {
    _closedSince = null;
    _minEar = double.infinity;
    _lastT = null;
    _lastEar = null;
    _maxVelocity = 0.0;
  }

  double closedDurationMs(double nowS) =>
      _closedSince == null ? 0.0 : (nowS - _closedSince!) * 1000.0;

  BlinkEvent? update(double tS, double ear) {
    if (!tS.isFinite || !ear.isFinite) {
      reset();
      return null;
    }
    var velocity = 0.0;
    if (_lastT != null) {
      final dt = tS - _lastT!;
      if (dt > 0) velocity = (_lastEar! - ear) / dt;
    }
    _lastT = tS;
    _lastEar = ear;
    final closed = ear < threshold;
    if (closed) {
      if (_closedSince == null) {
        _closedSince = tS;
        _minEar = ear;
        _maxVelocity = math.max(velocity, 0.0);
      } else {
        _minEar = math.min(_minEar, ear);
        _maxVelocity = math.max(_maxVelocity, velocity);
      }
      return null;
    }
    if (_closedSince == null) return null;
    final start = _closedSince!;
    _closedSince = null;
    final durationMs = (tS - start) * 1000.0;
    final depth = (1.0 - _minEar / openEar).clamp(0.0, 1.0).toDouble();
    _minEar = double.infinity;
    if (durationMs < minDurationMs) return null;
    return BlinkEvent(start, tS, depth, _maxVelocity);
  }
}

class BlinkStatistics {
  const BlinkStatistics({
    required this.count,
    required this.rateHz,
    required this.meanDurationMs,
    required this.sdDurationMs,
    required this.durationCv,
    required this.meanIntervalS,
    required this.intervalCv,
    required this.meanDepth,
    required this.meanVelocity,
  });

  final double count;
  final double rateHz;
  final double meanDurationMs;
  final double sdDurationMs;
  final double durationCv;
  final double meanIntervalS;
  final double intervalCv;
  final double meanDepth;
  final double meanVelocity;

  static const empty = BlinkStatistics(
    count: 0,
    rateHz: 0,
    meanDurationMs: 0,
    sdDurationMs: 0,
    durationCv: 0,
    meanIntervalS: 0,
    intervalCv: 0,
    meanDepth: 0,
    meanVelocity: 0,
  );
}

BlinkStatistics blinkStatistics(List<BlinkEvent> events, double spanS) {
  final span = math.max(spanS, 1e-6);
  final n = events.length;
  if (n == 0) return BlinkStatistics.empty;
  final durations = events.map((e) => e.durationMs).toList();
  final meanDuration = durations.reduce((a, b) => a + b) / n;
  final sdDuration = math.sqrt(durations
          .map((d) => (d - meanDuration) * (d - meanDuration))
          .reduce((a, b) => a + b) /
      n);
  var meanInterval = 0.0;
  var intervalCv = 0.0;
  if (n > 1) {
    final intervals = <double>[
      for (var i = 1; i < n; i++) events[i].startS - events[i - 1].endS,
    ];
    meanInterval = intervals.reduce((a, b) => a + b) / intervals.length;
    final sdInterval = math.sqrt(intervals
            .map((v) => (v - meanInterval) * (v - meanInterval))
            .reduce((a, b) => a + b) /
        intervals.length);
    intervalCv = meanInterval > 0 ? sdInterval / meanInterval : 0.0;
  }
  return BlinkStatistics(
    count: n.toDouble(),
    rateHz: n / span,
    meanDurationMs: meanDuration,
    sdDurationMs: sdDuration,
    durationCv: meanDuration > 0 ? sdDuration / meanDuration : 0.0,
    meanIntervalS: meanInterval,
    intervalCv: intervalCv,
    meanDepth: events.map((e) => e.depth).reduce((a, b) => a + b) / n,
    meanVelocity:
        events.map((e) => e.closingVelocity).reduce((a, b) => a + b) / n,
  );
}

/// np.percentile with linear interpolation.
double percentile(List<double> values, double q) {
  final sorted = List<double>.from(values)..sort();
  if (sorted.isEmpty) return 0.0;
  final position = (q / 100.0) * (sorted.length - 1);
  final lower = position.floor();
  final upper = math.min(lower + 1, sorted.length - 1);
  final frac = position - lower;
  return sorted[lower] + frac * (sorted[upper] - sorted[lower]);
}

List<BlinkEvent> detectBlinks(List<double> timestamps, List<double> ear,
    {double? openEar}) {
  if (ear.isEmpty) return const [];
  final baseline = (openEar != null && openEar > 0) ? openEar : percentile(ear, 80);
  final detector = BlinkDetector(openEar: math.max(baseline, 1e-3));
  final events = <BlinkEvent>[];
  for (var i = 0; i < ear.length; i++) {
    final event = detector.update(timestamps[i], ear[i]);
    if (event != null) events.add(event);
  }
  return events;
}

/// np.gradient(f, dt) for a 1-D series.
List<double> gradient(List<double> f, double dt) {
  final n = f.length;
  if (n < 2) return List<double>.filled(n, 0.0);
  final out = List<double>.filled(n, 0.0);
  out[0] = (f[1] - f[0]) / dt;
  out[n - 1] = (f[n - 1] - f[n - 2]) / dt;
  for (var i = 1; i < n - 1; i++) {
    out[i] = (f[i + 1] - f[i - 1]) / (2 * dt);
  }
  return out;
}

class TrajectoryMetrics {
  const TrajectoryMetrics({
    this.velocityRms = 0,
    this.accelRms = 0,
    this.jerkRms = 0,
    this.smoothness = 0,
    this.directionConsistency = 0,
    this.holdFraction = 0,
    this.onsetCount = 0,
    this.peakAmplitude = 0,
    this.dominantHz = 0,
    this.rhythmicity = 0,
    this.sustainedSeconds = 0,
  });

  final double velocityRms;
  final double accelRms;
  final double jerkRms;
  final double smoothness;
  final double directionConsistency;
  final double holdFraction;
  final int onsetCount;
  final double peakAmplitude;
  final double dominantHz;
  final double rhythmicity;
  final double sustainedSeconds;
}

/// Returns (dominant frequency, rhythmicity) like trajectory.dominant_frequency.
({double dominantHz, double rhythmicity}) dominantFrequency(
    List<double> signal, double rateHz,
    {double minHz = 0.5}) {
  final n = signal.length;
  if (n < 8 || signal.any((v) => !v.isFinite)) {
    return (dominantHz: 0.0, rhythmicity: 0.0);
  }
  final mean = signal.reduce((a, b) => a + b) / n;
  final x = signal.map((v) => v - mean).toList();
  if (x.every((v) => v.abs() <= 1e-8)) {
    return (dominantHz: 0.0, rhythmicity: 0.0);
  }
  // Hann-windowed real DFT magnitude (naive O(n^2); n <= 60).
  final windowed = List<double>.generate(
      n, (i) => x[i] * (0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1))));
  final bins = n ~/ 2 + 1;
  var bestBin = -1;
  var bestMag = -1.0;
  for (var k = 0; k < bins; k++) {
    final freq = k * rateHz / n;
    if (freq < minHz) continue;
    var re = 0.0;
    var im = 0.0;
    for (var i = 0; i < n; i++) {
      final angle = -2 * math.pi * k * i / n;
      re += windowed[i] * math.cos(angle);
      im += windowed[i] * math.sin(angle);
    }
    final mag = math.sqrt(re * re + im * im);
    if (mag > bestMag) {
      bestMag = mag;
      bestBin = k;
    }
  }
  final dominant = bestBin < 0 ? 0.0 : bestBin * rateHz / n;
  // Autocorrelation normalised by lag 0; first local maximum after lag 1.
  final auto = List<double>.generate(n, (lag) {
    var s = 0.0;
    for (var i = 0; i + lag < n; i++) {
      s += x[i] * x[i + lag];
    }
    return s;
  });
  final norm = auto[0] > 0 ? auto[0] : 1.0;
  for (var i = 0; i < n; i++) {
    auto[i] /= norm;
  }
  var rhythm = 0.0;
  for (var lag = 2; lag < n - 1; lag++) {
    if (auto[lag] > auto[lag - 1] && auto[lag] >= auto[lag + 1]) {
      rhythm = math.max(0.0, auto[lag]);
      break;
    }
  }
  return (dominantHz: dominant, rhythmicity: rhythm);
}

/// Centred trajectory projected onto its principal axis (2x2 covariance).
List<double> principalProjection(List<double> xs, List<double> ys) {
  final n = xs.length;
  final mx = xs.reduce((a, b) => a + b) / n;
  final my = ys.reduce((a, b) => a + b) / n;
  var a = 0.0;
  var b = 0.0;
  var d = 0.0;
  for (var i = 0; i < n; i++) {
    final cx = xs[i] - mx;
    final cy = ys[i] - my;
    a += cx * cx;
    b += cx * cy;
    d += cy * cy;
  }
  final theta = 0.5 * math.atan2(2.0 * b, a - d);
  final ux = math.cos(theta);
  final uy = math.sin(theta);
  return List<double>.generate(n, (i) => (xs[i] - mx) * ux + (ys[i] - my) * uy);
}

({int onsets, double holdFraction, double sustainedSeconds}) segmentPhases(
    List<double> speed, double dt,
    {required double moveThreshold, double? holdThreshold}) {
  if (speed.isEmpty) return (onsets: 0, holdFraction: 0.0, sustainedSeconds: 0.0);
  final hold = holdThreshold ?? moveThreshold * 0.5;
  final moving = speed.map((s) => s > moveThreshold).toList();
  var onsets = moving[0] ? 1 : 0;
  for (var i = 1; i < moving.length; i++) {
    if (moving[i] && !moving[i - 1]) onsets++;
  }
  final first = moving.indexOf(true);
  if (first < 0) return (onsets: 0, holdFraction: 0.0, sustainedSeconds: 0.0);
  var below = 0;
  for (var i = first; i < speed.length; i++) {
    if (speed[i] < hold) below++;
  }
  final holdFraction = below / (speed.length - first);
  var longest = 0;
  var current = 0;
  for (final flag in moving) {
    current = flag ? current + 1 : 0;
    if (current > longest) longest = current;
  }
  return (onsets: onsets, holdFraction: holdFraction, sustainedSeconds: longest * dt);
}

TrajectoryMetrics analyzeTrajectory(
    List<double> xs, List<double> ys, double dt, double rateHz) {
  final n = xs.length;
  if (n < 3 || ys.length != n) return const TrajectoryMetrics();
  final vx = gradient(xs, dt);
  final vy = gradient(ys, dt);
  final ax = gradient(vx, dt);
  final ay = gradient(vy, dt);
  final jx = gradient(ax, dt);
  final jy = gradient(ay, dt);
  final speed = List<double>.generate(n, (i) => math.sqrt(vx[i] * vx[i] + vy[i] * vy[i]));
  double rms(List<double> a, List<double> b) {
    var s = 0.0;
    for (var i = 0; i < n; i++) {
      s += a[i] * a[i] + b[i] * b[i];
    }
    return math.sqrt(s / n);
  }

  final velocityRms = math.sqrt(speed.map((s) => s * s).reduce((a, b) => a + b) / n);
  final accelRms = rms(ax, ay);
  final jerkRms = rms(jx, jy);
  final duration = dt * (n - 1);
  final peakSpeed = speed.reduce(math.max);
  var smoothness = 0.0;
  if (peakSpeed > 1e-9 && duration > 0) {
    var jerkEnergy = 0.0;
    for (var i = 0; i < n; i++) {
      jerkEnergy += jx[i] * jx[i] + jy[i] * jy[i];
    }
    final ldj = -math.log((math.pow(duration, 3) / (peakSpeed * peakSpeed)) * jerkEnergy * dt);
    smoothness = ldj.clamp(-30.0, 0.0).toDouble();
  }
  var cosSum = 0.0;
  var sinSum = 0.0;
  var headings = 0;
  for (var i = 0; i < n; i++) {
    if (speed[i] > 1e-6) {
      final heading = math.atan2(vy[i], vx[i]);
      cosSum += math.cos(heading);
      sinSum += math.sin(heading);
      headings++;
    }
  }
  final directionConsistency = headings == 0
      ? 0.0
      : math.sqrt(math.pow(cosSum / headings, 2) + math.pow(sinSum / headings, 2));
  final moveThreshold = math.max(0.25 * peakSpeed, 1e-6);
  final phases = segmentPhases(speed, dt, moveThreshold: moveThreshold);
  var peakAmplitude = 0.0;
  for (var i = 0; i < n; i++) {
    final d = math.sqrt(math.pow(xs[i] - xs[0], 2) + math.pow(ys[i] - ys[0], 2));
    if (d > peakAmplitude) peakAmplitude = d;
  }
  final freq = dominantFrequency(principalProjection(xs, ys), rateHz);
  return TrajectoryMetrics(
    velocityRms: velocityRms,
    accelRms: accelRms,
    jerkRms: jerkRms,
    smoothness: smoothness,
    directionConsistency: directionConsistency,
    holdFraction: phases.holdFraction,
    onsetCount: phases.onsets,
    peakAmplitude: peakAmplitude,
    dominantHz: freq.dominantHz,
    rhythmicity: freq.rhythmicity,
    sustainedSeconds: phases.sustainedSeconds,
  );
}

/// Aggregate a window of frames into the 182-value classifier vector.
List<double> windowFeatures(List<IntentFrame> frames,
    {double rateHz = kFrameRateHz, double? openEar}) {
  if (frames.isEmpty) throw ArgumentError('window must contain a frame');
  final n = frames.length;
  final out = <double>[];
  // Per-channel statistics, channel-major.
  for (var c = 0; c < kFrameFeatureCount; c++) {
    var sum = 0.0;
    var minv = double.infinity;
    var maxv = double.negativeInfinity;
    for (final f in frames) {
      final v = f.values[c];
      sum += v;
      if (v < minv) minv = v;
      if (v > maxv) maxv = v;
    }
    final mean = sum / n;
    var varSum = 0.0;
    for (final f in frames) {
      final d = f.values[c] - mean;
      varSum += d * d;
    }
    var mad = 0.0;
    if (n > 1) {
      for (var i = 1; i < n; i++) {
        mad += (frames[i].values[c] - frames[i - 1].values[c]).abs();
      }
      mad /= (n - 1);
    }
    out.addAll([mean, math.sqrt(varSum / n), minv, maxv, maxv - minv, mad]);
  }
  final times = frames.map((f) => f.tSeconds).toList();
  var span = n > 1 ? times.last - times.first : 1.0 / rateHz;
  span = math.max(span, 1.0 / rateHz);
  final dt = 1.0 / rateHz;

  final ear = frames.map((f) => f.values[F.earMean]).toList();
  final blinks = blinkStatistics(detectBlinks(times, ear, openEar: openEar), span);

  final head = analyzeTrajectory(
    frames.map((f) => f.values[F.headYaw]).toList(),
    frames.map((f) => f.values[F.headPitch]).toList(),
    dt,
    rateHz,
  );
  final face = analyzeTrajectory(
    frames.map((f) => f.values[F.faceCx]).toList(),
    frames.map((f) => f.values[F.faceCy]).toList(),
    dt,
    rateHz,
  );

  final mouthGrad = gradient(frames.map((f) => f.values[F.mouthOpenRatio]).toList(), dt);
  final browGrad = gradient(frames.map((f) => f.values[F.browRaise]).toList(), dt);
  final activity = List<double>.generate(n, (i) {
    final f = frames[i].values;
    return f[F.headAngularSpeed].abs() / 60.0 +
        f[F.handSpeed] * 2.0 +
        f[F.flowMagMean] * 4.0 +
        mouthGrad[i].abs() * 0.5 +
        browGrad[i].abs() * 0.5;
  });
  final peak = activity.reduce(math.max);
  final phases = segmentPhases(activity, dt, moveThreshold: math.max(0.25 * peak, 1e-6));

  out.addAll([
    blinks.count,
    blinks.meanDurationMs,
    blinks.durationCv,
    blinks.intervalCv,
    blinks.rateHz,
    head.dominantHz,
    head.rhythmicity,
    face.jerkRms,
    face.smoothness,
    phases.holdFraction,
    math.max(head.directionConsistency, face.directionConsistency),
    phases.onsets.toDouble(),
    peak,
    phases.sustainedSeconds,
  ]);
  assert(out.length == kWindowFeatureCount);
  return out;
}

/// Ring buffer of frames feeding the classifiers and the temporal model.
class FeatureWindow {
  FeatureWindow({
    this.windowFrames = kWindowFrames,
    int? sequenceFrames,
    this.rateHz = kFrameRateHz,
  }) : sequenceFrames = sequenceFrames ?? windowFrames;

  final int windowFrames;
  final int sequenceFrames;
  final double rateHz;
  final List<IntentFrame> _frames = [];

  int get capacity => math.max(windowFrames, sequenceFrames);
  int get length => _frames.length;
  bool get isReady => _frames.length >= math.min(windowFrames, sequenceFrames);
  IntentFrame? get latest => _frames.isEmpty ? null : _frames.last;

  void clear() => _frames.clear();

  void push(IntentFrame frame) {
    if (_frames.isNotEmpty && frame.tSeconds < _frames.last.tSeconds) {
      _frames.clear();
    }
    _frames.add(frame);
    if (_frames.length > capacity) _frames.removeAt(0);
  }

  List<IntentFrame> window() =>
      _frames.sublist(math.max(0, _frames.length - windowFrames));

  List<double> features({double? openEar}) =>
      windowFeatures(window(), rateHz: rateHz, openEar: openEar);

  /// Last [sequenceFrames] frames as (T, C); front-padded with the first frame.
  List<List<double>> sequence() {
    if (_frames.isEmpty) {
      return List.generate(sequenceFrames, (_) => List.filled(kFrameFeatureCount, 0.0));
    }
    final tail = _frames.sublist(math.max(0, _frames.length - sequenceFrames));
    final rows = tail.map((f) => List<double>.from(f.values)).toList();
    while (rows.length < sequenceFrames) {
      rows.insert(0, List<double>.from(tail.first.values));
    }
    return rows;
  }

  double secondsCovered() =>
      _frames.length < 2 ? 0.0 : _frames.last.tSeconds - _frames.first.tSeconds;
}
