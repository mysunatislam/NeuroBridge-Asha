// hand_gesture_classifier.dart
// Three-tier gesture classifier — exact port of fingerspeak.html classifiers.
//   1. DTW k-NN (k=3)
//   2. Nearest-prototype
//   3. OOD Guard

import 'dart:math' as math;
import 'hand_feature_extractor.dart';

// ── Euclidean distance ────────────────────────────────────────────────────────

double euclid(List<double> a, List<double> b) {
  var s = 0.0;
  for (var i = 0; i < a.length; i++) {
    final d = a[i] - b[i];
    s += d * d;
  }
  return math.sqrt(s);
}

// ── Summary vector (mean + std per dimension) ─────────────────────────────────

List<double> summaryVector(List<List<double>> seq) {
  final dims = seq.first.length;
  final mean = List<double>.filled(dims, 0.0);
  for (final f in seq) {
    for (var d = 0; d < dims; d++) {
      mean[d] += f[d] / seq.length;
    }
  }
  final std = List<double>.filled(dims, 0.0);
  for (final f in seq) {
    for (var d = 0; d < dims; d++) {
      std[d] += (f[d] - mean[d]) * (f[d] - mean[d]) / seq.length;
    }
  }
  for (var d = 0; d < dims; d++) {
    std[d] = math.sqrt(std[d]);
  }
  return [...mean, ...std];
}

// ── DTW k-NN ──────────────────────────────────────────────────────────────────

double dtwDistance(List<List<double>> seqA, List<List<double>> seqB) {
  final n = seqA.length;
  final m = seqB.length;
  var prev = List<double>.filled(m + 1, double.infinity);
  var curr = List<double>.filled(m + 1, double.infinity);
  prev[0] = 0;
  for (var i = 1; i <= n; i++) {
    curr[0] = double.infinity;
    for (var j = 1; j <= m; j++) {
      final cost = euclid(seqA[i - 1], seqB[j - 1]);
      curr[j] = cost + [prev[j], curr[j - 1], prev[j - 1]].reduce(math.min);
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[m];
}

class _DTWEntry {
  _DTWEntry(this.trainSeq, this.classIdx);
  final List<List<double>> trainSeq;
  final int classIdx;
}

class DTWClassifier {
  final List<_DTWEntry> _entries = [];
  int numClasses = 0;

  void train(List<List<List<List<double>>>> trainSeqsByClass) {
    _entries.clear();
    numClasses = trainSeqsByClass.length;
    for (var c = 0; c < trainSeqsByClass.length; c++) {
      for (final seq in trainSeqsByClass[c]) {
        _entries.add(_DTWEntry(seq, c));
      }
    }
  }

  List<double> classify(List<List<double>> querySeq) {
    if (_entries.isEmpty) return List.filled(numClasses, 1.0 / numClasses);
    final dists = _entries
        .map((e) => MapEntry(e.classIdx, dtwDistance(querySeq, e.trainSeq)))
        .toList()
      ..sort((a, b) => a.value.compareTo(b.value));
    final topK = dists.take(dtwK).toList();
    final votes = <int, double>{};
    for (final e in topK) {
      votes[e.key] = (votes[e.key] ?? 0) + 1.0 / (1 + e.value);
    }
    final total = votes.values.fold(0.0, (s, v) => s + v);
    final probs = List<double>.filled(numClasses, 0.0);
    votes.forEach((c, v) => probs[c] = total > 0 ? v / total : 0.0);
    return probs;
  }
}

// ── Nearest-prototype ─────────────────────────────────────────────────────────

class _Prototype {
  _Prototype(this.centroid, this.spread);
  final List<double> centroid;
  final double spread;
}

class NearestPrototypeClassifier {
  final List<_Prototype> _protos = [];

  void train(List<List<List<List<double>>>> trainSeqsByClass) {
    _protos.clear();
    for (final seqs in trainSeqsByClass) {
      if (seqs.isEmpty) {
        _protos.add(_Prototype(List<double>.filled(featureLen * 2, 0.0), 0.05));
        continue;
      }
      final summaries = seqs.map(summaryVector).toList();
      if (summaries.isEmpty) {
        _protos.add(_Prototype(List<double>.filled(featureLen * 2, 0.0), 0.05));
        continue;
      }
      final dims = summaries.first.length;
      final centroid = List<double>.filled(dims, 0.0);
      for (final s in summaries) {
        for (var d = 0; d < dims; d++) {
          centroid[d] += s[d] / summaries.length;
        }
      }
      final spread = summaries
              .map((s) => euclid(s, centroid))
              .fold(0.0, (a, b) => a + b) /
          summaries.length;
      _protos.add(_Prototype(centroid, math.max(spread, 0.05)));
    }
  }

  List<double> classify(List<List<double>> querySeq) {
    if (_protos.isEmpty) return [];
    final q = summaryVector(querySeq);
    final sims =
        _protos.map((p) => 1.0 / (1 + euclid(q, p.centroid))).toList();
    final total = sims.fold(0.0, (a, b) => a + b);
    return sims.map((s) => total > 0 ? s / total : 0.0).toList();
  }
}

// ── OOD guard ─────────────────────────────────────────────────────────────────

class OODGuard {
  List<_Prototype>? _protos;

  void build(List<List<List<List<double>>>> trainSeqsByClass) {
    _protos = trainSeqsByClass
        .where((seqs) => seqs.isNotEmpty)
        .map((seqs) {
      final summaries = seqs.map(summaryVector).toList();
      final dims = summaries.first.length;
      final centroid = List<double>.filled(dims, 0.0);
      for (final s in summaries) {
        for (var d = 0; d < dims; d++) {
          centroid[d] += s[d] / summaries.length;
        }
      }
      final spread = summaries
              .map((s) => euclid(s, centroid))
              .fold(0.0, (a, b) => a + b) /
          summaries.length;
      return _Prototype(centroid, math.max(spread, 0.05));
    }).toList();
  }

  bool isInDistribution(List<List<double>> querySeq) {
    final p = _protos;
    if (p == null) return true;
    final q = summaryVector(querySeq);
    return p.any((proto) => euclid(q, proto.centroid) <= proto.spread * oodMultiplier);
  }

  void clear() => _protos = null;
}

// ── Unified facade ────────────────────────────────────────────────────────────

enum ClassifierType { dtw, prototype }

class ClassifyResult {
  const ClassifyResult({
    required this.probs,
    required this.maxIdx,
    required this.confidence,
    required this.inDistribution,
  });
  final List<double> probs;
  final int maxIdx;
  final double confidence;
  final bool inDistribution;
}

class HandGestureClassifier {
  final DTWClassifier _dtw = DTWClassifier();
  final NearestPrototypeClassifier _proto = NearestPrototypeClassifier();
  final OODGuard _ood = OODGuard();

  ClassifierType activeType = ClassifierType.dtw;
  bool isTrained = false;

  void train(List<List<List<List<double>>>> trainSeqsByClass) {
    _dtw.train(trainSeqsByClass);
    _proto.train(trainSeqsByClass);
    _ood.build(trainSeqsByClass);
    isTrained = true;
  }

  void reset() {
    _dtw.numClasses = 0;
    _ood.clear();
    isTrained = false;
  }

  ClassifyResult classify(List<List<double>> querySeq, int numClasses) {
    if (!isTrained) {
      return ClassifyResult(
        probs: List.filled(numClasses, 1.0 / numClasses),
        maxIdx: 0,
        confidence: 0.0,
        inDistribution: false,
      );
    }
    final probs = activeType == ClassifierType.dtw
        ? _dtw.classify(querySeq)
        : _proto.classify(querySeq);
    final maxIdx =
        probs.isEmpty ? 0 : probs.indexOf(probs.reduce(math.max));
    final confidence = probs.isEmpty ? 0.0 : probs[maxIdx];
    return ClassifyResult(
      probs: probs,
      maxIdx: maxIdx,
      confidence: confidence,
      inDistribution: _ood.isInDistribution(querySeq),
    );
  }
}
