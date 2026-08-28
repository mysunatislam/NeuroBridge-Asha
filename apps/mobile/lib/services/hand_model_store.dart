// hand_model_store.dart
// Persists the trained gesture vocabulary + raw sample sequences to the app
// documents directory as a JSON file.

import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'hand_gesture_state_machine.dart';

const _profileFile = 'fingerspeak_hand_profile.json';
const _prefKey = 'hand_gestures_trained';

class HandModelStore {
  static Future<bool> save(List<HandGesture> gestures) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_profileFile');
      final gestureData = gestures.map((g) => {
            ...g.toJson(),
            'samples': g.samples
                .map((seq) => seq.map((frame) => frame).toList())
                .toList(),
          }).toList();
      await file.writeAsString(jsonEncode({
        'version': 2,
        'appVersion': '2.0',
        'savedAt': DateTime.now().millisecondsSinceEpoch,
        'gestures': gestureData,
      }));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, true);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<List<HandGesture>?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_prefKey) != true) return null;
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_profileFile');
      if (!await file.exists()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final items = json['gestures'] as List<dynamic>;
      return _parseGestures(items);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> exportPath() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_profileFile');
      return await file.exists() ? file.path : null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<HandGesture>?> importFrom(String filePath) async {
    try {
      final src = File(filePath);
      final json =
          jsonDecode(await src.readAsString()) as Map<String, dynamic>;
      final items = json['gestures'] as List<dynamic>;
      return _parseGestures(items);
    } catch (_) {
      return null;
    }
  }

  static List<HandGesture> _parseGestures(List<dynamic> items) {
    return items.map((item) {
      final map = item as Map<String, dynamic>;
      final g = HandGesture.fromJson(map);
      final rawSamples = map['samples'] as List<dynamic>? ?? [];
      for (final seqRaw in rawSamples) {
        final frames = seqRaw as List<dynamic>;
        final seq = frames.map((frameRaw) {
          return (frameRaw as List<dynamic>)
              .map((v) => (v as num).toDouble())
              .toList();
        }).toList();
        g.samples.add(seq);
      }
      return g;
    }).toList();
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_profileFile');
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }
}
