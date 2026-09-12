// tree_ensemble.dart
// Evaluates the JSON forest exported by
// services/intent/src/neurobridge_intent/models/tree_export.py.
//
// Decisions are `value <= threshold` on doubles, exactly as scikit-learn and
// the Python reference runtime do, so predictions are identical on device.

import 'dart:typed_data';

class _Tree {
  _Tree({
    required this.left,
    required this.right,
    required this.feature,
    required this.threshold,
    required this.value,
    required this.classCount,
  });

  final Int32List left;
  final Int32List right;
  final Int32List feature;
  final Float64List threshold;
  final Float64List value; // flattened (nodes x classes)
  final int classCount;

  int leaf(List<double> x) {
    var node = 0;
    while (left[node] != -1) {
      node = x[feature[node]] <= threshold[node] ? left[node] : right[node];
    }
    return node;
  }
}

class TreeEnsembleRuntime {
  TreeEnsembleRuntime._(this.classes, this.featureCount, this._trees);

  final List<String> classes;
  final int featureCount;
  final List<_Tree> _trees;

  factory TreeEnsembleRuntime.fromJson(Map<String, dynamic> spec) {
    if (spec['type'] != 'forest') {
      throw const FormatException('spec is not a forest');
    }
    final classes = (spec['classes'] as List).cast<String>();
    final featureCount = spec['n_features'] as int;
    final trees = <_Tree>[];
    for (final raw in spec['trees'] as List) {
      final tree = raw as Map<String, dynamic>;
      final values = (tree['value'] as List);
      final flat = Float64List(values.length * classes.length);
      for (var i = 0; i < values.length; i++) {
        final row = values[i] as List;
        for (var j = 0; j < classes.length; j++) {
          flat[i * classes.length + j] = (row[j] as num).toDouble();
        }
      }
      trees.add(_Tree(
        left: Int32List.fromList((tree['left'] as List).cast<int>()),
        right: Int32List.fromList((tree['right'] as List).cast<int>()),
        feature: Int32List.fromList((tree['feature'] as List).cast<int>()),
        threshold: Float64List.fromList(
            (tree['threshold'] as List).map((v) => (v as num).toDouble()).toList()),
        value: flat,
        classCount: classes.length,
      ));
    }
    return TreeEnsembleRuntime._(classes, featureCount, trees);
  }

  int get treeCount => _trees.length;

  List<double> predictProba(List<double> x) {
    if (x.length != featureCount) {
      throw ArgumentError('expected $featureCount features, got ${x.length}');
    }
    final total = List<double>.filled(classes.length, 0.0);
    for (final tree in _trees) {
      final leaf = tree.leaf(x);
      for (var j = 0; j < classes.length; j++) {
        total[j] += tree.value[leaf * tree.classCount + j];
      }
    }
    if (_trees.isEmpty) return total;
    for (var j = 0; j < total.length; j++) {
      total[j] /= _trees.length;
    }
    return total;
  }

  String predict(List<double> x) {
    final proba = predictProba(x);
    var best = 0;
    for (var j = 1; j < proba.length; j++) {
      if (proba[j] > proba[best]) best = j;
    }
    return classes[best];
  }
}
