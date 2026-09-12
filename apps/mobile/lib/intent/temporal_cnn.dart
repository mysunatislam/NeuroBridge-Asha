// temporal_cnn.dart
// Pure-Dart evaluator for the temporal CNN exported by
// services/intent/src/neurobridge_intent/models/temporal.py.
//
//   (T, C) -> Conv1D(k5) -> ReLU -> Conv1D(k5, s2) -> ReLU -> Conv1D(k3) -> ReLU
//          -> [global average ++ global max] -> Dense ReLU -> Dense softmax
//
// Conv padding is Keras "same": out_len = ceil(T / stride),
// pad_total = max((out_len - 1) * stride + k - T, 0), pad_left = pad_total ~/ 2.
// The model is tiny (tens of thousands of MACs), so it runs comfortably at the
// 4 Hz decision rate on a phone or in the browser.

import 'dart:math' as math;
import 'dart:typed_data';

abstract class _Layer {
  List<Float64List> apply(List<Float64List> x);
}

class _Conv1D implements _Layer {
  _Conv1D(this.kernel, this.bias, this.stride, this.k, this.cin, this.cout);

  final Float64List kernel; // (k, cin, cout) flattened
  final Float64List bias;
  final int stride;
  final int k;
  final int cin;
  final int cout;

  @override
  List<Float64List> apply(List<Float64List> x) {
    final t = x.length;
    final outLen = (t + stride - 1) ~/ stride;
    final padTotal = math.max((outLen - 1) * stride + k - t, 0);
    final padLeft = padTotal ~/ 2;
    final out = List<Float64List>.generate(outLen, (_) => Float64List(cout));
    for (var i = 0; i < outLen; i++) {
      final row = out[i];
      for (var o = 0; o < cout; o++) {
        row[o] = bias[o];
      }
      final start = i * stride - padLeft;
      for (var kk = 0; kk < k; kk++) {
        final src = start + kk;
        if (src < 0 || src >= t) continue;
        final frame = x[src];
        final base = kk * cin * cout;
        for (var c = 0; c < cin; c++) {
          final v = frame[c];
          if (v == 0.0) continue;
          final off = base + c * cout;
          for (var o = 0; o < cout; o++) {
            row[o] += v * kernel[off + o];
          }
        }
      }
      for (var o = 0; o < cout; o++) {
        if (row[o] < 0) row[o] = 0.0; // ReLU
      }
    }
    return out;
  }
}

class _GlobalPool implements _Layer {
  @override
  List<Float64List> apply(List<Float64List> x) {
    final c = x.first.length;
    final mean = Float64List(c);
    final maxv = Float64List(c);
    for (var j = 0; j < c; j++) {
      maxv[j] = double.negativeInfinity;
    }
    for (final row in x) {
      for (var j = 0; j < c; j++) {
        mean[j] += row[j];
        if (row[j] > maxv[j]) maxv[j] = row[j];
      }
    }
    final out = Float64List(2 * c);
    for (var j = 0; j < c; j++) {
      out[j] = mean[j] / x.length;
      out[c + j] = maxv[j];
    }
    return [out];
  }
}

class _Dense implements _Layer {
  _Dense(this.kernel, this.bias, this.cin, this.cout, this.relu);

  final Float64List kernel; // (cin, cout)
  final Float64List bias;
  final int cin;
  final int cout;
  final bool relu;

  @override
  List<Float64List> apply(List<Float64List> x) {
    final input = x.first;
    final out = Float64List(cout);
    for (var o = 0; o < cout; o++) {
      var acc = bias[o];
      for (var i = 0; i < cin; i++) {
        acc += input[i] * kernel[i * cout + o];
      }
      out[o] = relu && acc < 0 ? 0.0 : acc;
    }
    return [out];
  }
}

class TemporalCnnRuntime {
  TemporalCnnRuntime._(
    this.classes,
    this.sequenceFrames,
    this.channels,
    this._layers,
    this._normMean,
    this._normStd,
  );

  final List<String> classes;
  final int sequenceFrames;
  final int channels;
  final List<_Layer> _layers;
  final Float64List _normMean;
  final Float64List _normStd;

  factory TemporalCnnRuntime.fromJson(Map<String, dynamic> spec) {
    if (spec['type'] != 'temporal_cnn') {
      throw const FormatException('spec is not a temporal_cnn export');
    }
    final classes = (spec['classes'] as List).cast<String>();
    final sequenceFrames = spec['sequence_frames'] as int;
    final channels = spec['channels'] as int;
    final norm = spec['normalizer'] as Map<String, dynamic>;
    final layers = <_Layer>[];
    for (final raw in spec['layers'] as List) {
      final layer = raw as Map<String, dynamic>;
      final weights = layer['weights'] as Map<String, dynamic>;
      switch (layer['kind'] as String) {
        case 'conv1d':
          final kernel = weights['kernel'] as List; // (k, cin, cout)
          final k = kernel.length;
          final cin = (kernel[0] as List).length;
          final cout = ((kernel[0] as List)[0] as List).length;
          final flat = Float64List(k * cin * cout);
          for (var a = 0; a < k; a++) {
            final plane = kernel[a] as List;
            for (var b = 0; b < cin; b++) {
              final row = plane[b] as List;
              for (var c = 0; c < cout; c++) {
                flat[a * cin * cout + b * cout + c] = (row[c] as num).toDouble();
              }
            }
          }
          layers.add(_Conv1D(flat, _vec(weights['bias']), layer['stride'] as int,
              k, cin, cout));
        case 'global_pool':
          layers.add(_GlobalPool());
        case 'dense':
          final kernel = weights['kernel'] as List; // (cin, cout)
          final cin = kernel.length;
          final cout = (kernel[0] as List).length;
          final flat = Float64List(cin * cout);
          for (var i = 0; i < cin; i++) {
            final row = kernel[i] as List;
            for (var o = 0; o < cout; o++) {
              flat[i * cout + o] = (row[o] as num).toDouble();
            }
          }
          layers.add(_Dense(flat, _vec(weights['bias']), cin, cout,
              layer['activation'] == 'relu'));
        default:
          throw FormatException('unknown layer kind ${layer['kind']}');
      }
    }
    return TemporalCnnRuntime._(classes, sequenceFrames, channels, layers,
        _vec(norm['mean']), _vec(norm['std']));
  }

  static Float64List _vec(Object? raw) => Float64List.fromList(
      (raw as List).map((v) => (v as num).toDouble()).toList());

  /// [sequence] is (T, C) in raw feature units unless [normalized] is true.
  List<double> predictProba(List<List<double>> sequence,
      {bool normalized = false}) {
    if (sequence.length != sequenceFrames ||
        sequence.any((row) => row.length != channels)) {
      throw ArgumentError('expected ($sequenceFrames, $channels) sequence');
    }
    var x = List<Float64List>.generate(sequenceFrames, (t) {
      final row = Float64List(channels);
      for (var c = 0; c < channels; c++) {
        var v = sequence[t][c];
        if (!normalized) v = (v - _normMean[c]) / _normStd[c];
        row[c] = v.clamp(-8.0, 8.0).toDouble();
      }
      return row;
    });
    for (final layer in _layers) {
      x = layer.apply(x);
    }
    return _softmax(x.first);
  }

  ({String label, double probability}) predict(List<List<double>> sequence,
      {bool normalized = false}) {
    final proba = predictProba(sequence, normalized: normalized);
    var best = 0;
    for (var i = 1; i < proba.length; i++) {
      if (proba[i] > proba[best]) best = i;
    }
    return (label: classes[best], probability: proba[best]);
  }

  static List<double> _softmax(Float64List logits) {
    var maxv = double.negativeInfinity;
    for (final v in logits) {
      if (v > maxv) maxv = v;
    }
    final exps = List<double>.generate(logits.length, (i) => math.exp(logits[i] - maxv));
    final sum = exps.fold<double>(0, (a, b) => a + b);
    return exps.map((e) => e / sum).toList();
  }
}
