// hand_feature_extractor.dart
// Exact Dart port of the feature-extraction pipeline in fingerspeak.html.
//
// Feature vector per frame (total 98 dimensions):
//   63  rotation-normalised 3-D landmark coordinates
//   10  finger joint angles  (radians / π)
//   10  fingertip pair distances (scale-normalised)
//   15  fingertip velocity components (Δcoord per frame)
//
// Sequence: SEQ_LEN = 20 frames resampled from a CAPTURE_WINDOW_MS = 900 ms
// sliding buffer.

import 'dart:math' as math;

// ── Landmark input type ───────────────────────────────────────────────────────

/// A single 3-D hand landmark (wrist = 0, fingertips = 4, 8, 12, 16, 20).
class HandLandmark {
  const HandLandmark(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;
}

/// A raw-coordinate snapshot with its capture timestamp in milliseconds.
class TimedFrame {
  const TimedFrame(this.t, this.raw63);
  final int t;

  /// Flat 63-element list: [x0, y0, z0, x1, y1, z1, …, x20, y20, z20].
  final List<double> raw63;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const int seqLen            = 20;
const int captureWindowMs   = 900;
const int liveBufferMaxMs   = 1400;
const int featureLen        = 98;
const int repsPerGesture    = 8;
const int augPerSample      = 6;
const double oodMultiplier  = 2.2;
const int dtwK              = 3;
const int releaseStreakNeeded = 5;

const List<int> fingertipIdx = [4, 8, 12, 16, 20];

const Map<String, List<int>> fingerChains = {
  'thumb':  [1, 2, 3, 4],
  'index':  [5, 6, 7, 8],
  'middle': [9, 10, 11, 12],
  'ring':   [13, 14, 15, 16],
  'pinky':  [17, 18, 19, 20],
};

// ── Vector helpers ────────────────────────────────────────────────────────────

List<double> _vnorm(List<double> v) {
  final l = math.sqrt(v[0]*v[0] + v[1]*v[1] + v[2]*v[2]);
  final d = l < 1e-9 ? 1e-9 : l;
  return [v[0]/d, v[1]/d, v[2]/d];
}
double _vdot(List<double> a, List<double> b) =>
    a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
List<double> _vcross(List<double> a, List<double> b) =>
    [a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0]];
List<double> _vsub(List<double> a, List<double> b) =>
    [a[0]-b[0], a[1]-b[1], a[2]-b[2]];
List<double> _vscale(List<double> v, double s) =>
    [v[0]*s, v[1]*s, v[2]*s];

// ── Feature extraction ────────────────────────────────────────────────────────

/// Flatten 21 [HandLandmark] objects into a raw 63-element list.
List<double> flattenLandmarks(List<HandLandmark> lm) {
  final out = List<double>.filled(63, 0.0);
  for (var i = 0; i < 21; i++) {
    out[i*3]   = lm[i].x;
    out[i*3+1] = lm[i].y;
    out[i*3+2] = lm[i].z;
  }
  return out;
}

/// Compute the 83-element engineered feature vector from 63 raw coords.
/// Mirrors computeFullFeatures() in fingerspeak.html exactly.
List<double> computeFullFeatures(List<double> raw63) {
  List<double> P(int i) => [raw63[i*3], raw63[i*3+1], raw63[i*3+2]];

  final wrist    = P(0);
  final midMcp   = P(9);
  final indexMcp = P(5);
  final pinkyMcp = P(17);

  final midWristVec = _vsub(midMcp, wrist);
  final scaleLen = math.sqrt(
      midWristVec[0]*midWristVec[0] +
      midWristVec[1]*midWristVec[1] +
      midWristVec[2]*midWristVec[2]);
  final scale = scaleLen < 1e-9 ? 1e-9 : scaleLen;

  // Per-frame local hand basis — makes features rotation/position invariant.
  final eY = _vnorm(midWristVec);
  var hRaw = _vsub(pinkyMcp, indexMcp);
  final d = _vdot(hRaw, eY);
  hRaw = [hRaw[0]-d*eY[0], hRaw[1]-d*eY[1], hRaw[2]-d*eY[2]];
  final eX = _vnorm(hRaw);
  final eZ = _vnorm(_vcross(eX, eY));

  final coords = List<double>.filled(63, 0.0);
  for (var i = 0; i < 21; i++) {
    final rel = _vscale(_vsub(P(i), wrist), 1.0/scale);
    coords[i*3]   = _vdot(rel, eX);
    coords[i*3+1] = _vdot(rel, eY);
    coords[i*3+2] = _vdot(rel, eZ);
  }

  // 10 finger joint angles (2 per finger × 5 fingers).
  final angles = <double>[];
  for (final chain in fingerChains.values) {
    for (var j = 0; j < chain.length-2; j++) {
      final a = P(chain[j]);
      final b = P(chain[j+1]);
      final c = P(chain[j+2]);
      final v1 = _vnorm(_vsub(a, b));
      final v2 = _vnorm(_vsub(c, b));
      angles.add(math.acos(_vdot(v1, v2).clamp(-1.0, 1.0)) / math.pi);
    }
  }

  // 10 fingertip pair distances  C(5,2) = 10.
  final distances = <double>[];
  for (var i = 0; i < fingertipIdx.length; i++) {
    for (var j = i+1; j < fingertipIdx.length; j++) {
      final a = P(fingertipIdx[i]);
      final b = P(fingertipIdx[j]);
      distances.add(math.sqrt(
          (a[0]-b[0])*(a[0]-b[0]) +
          (a[1]-b[1])*(a[1]-b[1]) +
          (a[2]-b[2])*(a[2]-b[2])) / scale);
    }
  }

  return [...coords, ...angles, ...distances]; // 83
}

/// Append 15 fingertip velocity components → 98 features/frame.
List<List<double>> addVelocity(List<List<double>> seq) {
  final tipCI = fingertipIdx.map((i) => i*3).toList();
  return List.generate(seq.length, (idx) {
    final frame = seq[idx];
    final prev  = idx > 0 ? seq[idx-1] : frame;
    final vel   = <double>[];
    for (final ci in tipCI) {
      vel.add(frame[ci]   - prev[ci]);
      vel.add(frame[ci+1] - prev[ci+1]);
      vel.add(frame[ci+2] - prev[ci+2]);
    }
    return [...frame, ...vel]; // 98
  });
}

/// Full pipeline: raw63 sequence → 20×98 model input.
List<List<double>> buildModelInput(List<List<double>> rawSeq) =>
    addVelocity(rawSeq.map(computeFullFeatures).toList());

// ── Sequence resampling ───────────────────────────────────────────────────────

/// Resample a timed buffer to exactly [count] evenly-spaced frames over the
/// most recent [windowMs] milliseconds.  Returns null if fewer than 2 frames.
List<List<double>>? resampleSequence(
  List<TimedFrame> timedFrames, {
  int count    = seqLen,
  int windowMs = captureWindowMs,
}) {
  if (timedFrames.length < 2) return null;
  final latest = timedFrames.last.t;
  final start  = latest - windowMs;
  final inWin  = timedFrames.where((f) => f.t >= start - 50).toList();
  if (inWin.length < 2) return null;

  final out = <List<double>>[];
  for (var i = 0; i < count; i++) {
    final targetT = start + (i / (count-1)) * windowMs;
    var lo = inWin.first;
    var hi = inWin.last;
    for (var j = 0; j < inWin.length-1; j++) {
      if (inWin[j].t <= targetT && inWin[j+1].t >= targetT) {
        lo = inWin[j]; hi = inWin[j+1]; break;
      }
    }
    final span  = hi.t - lo.t;
    final alpha = span > 0 ? (targetT - lo.t) / span : 0.0;
    out.add(List.generate(lo.raw63.length,
        (k) => lo.raw63[k] + (hi.raw63[k] - lo.raw63[k]) * alpha));
  }
  return out;
}

// ── Data augmentation ─────────────────────────────────────────────────────────

final _rng = math.Random();

Map<String, double> _randomAffine() {
  final theta = (_rng.nextDouble() - 0.5) * 0.35;
  final s     = 0.9 + _rng.nextDouble() * 0.2;
  return {'cos': math.cos(theta), 'sin': math.sin(theta), 'scale': s};
}

List<List<double>> _applyAffine(
    List<List<double>> seq, Map<String, double> aff) {
  final cos = aff['cos']!; final sin = aff['sin']!; final s = aff['scale']!;
  return seq.map((frame) {
    final out = List<double>.from(frame);
    for (var i = 0; i < 63; i += 3) {
      final x = frame[i]; final y = frame[i+1]; final z = frame[i+2];
      out[i]   = (x*cos - y*sin) * s;
      out[i+1] = (x*sin + y*cos) * s;
      out[i+2] = z * s;
    }
    return out;
  }).toList();
}

List<List<double>> _timeWarp(List<List<double>> seq) {
  final n   = seq.length;
  final str = (_rng.nextDouble() - 0.5) * 0.6;
  return List.generate(n, (i) {
    final u   = i / (n-1);
    final w   = (u + str * math.sin(math.pi * u) * 0.3).clamp(0.0, 1.0);
    final pos = w * (n-1);
    final lo  = pos.floor();
    final hi  = math.min(n-1, lo+1);
    final a   = pos - lo;
    return List.generate(seq[lo].length,
        (k) => seq[lo][k] + (seq[hi][k] - seq[lo][k]) * a);
  });
}

List<List<double>> _jitter(List<List<double>> seq, {double sigma = 0.01}) =>
    seq.map((f) => f.map((v) => v + (_rng.nextDouble()*2-1)*sigma).toList()).toList();

/// One augmented variant of a raw 63-element landmark sequence.
List<List<double>> augmentRaw(List<List<double>> seq) =>
    _jitter(_timeWarp(_applyAffine(seq, _randomAffine())));

/// Build [n] augmented model inputs (20×98) from one raw sequence.
List<List<List<double>>> buildAugmentedInputs(List<List<double>> rawSeq, {int n = augPerSample}) =>
    List.generate(n, (_) => buildModelInput(augmentRaw(rawSeq)));
