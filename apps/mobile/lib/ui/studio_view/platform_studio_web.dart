// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use, unused_field
import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'platform_studio_stub.dart';

const _calibrationViewType = 'fingerspeak-studio-calibration-iframe';
const _patientViewType = 'fingerspeak-studio-patient-iframe';
final _registeredViews = <String>{};

Widget buildPlatformStudio({
  required BuildContext context,
  required GestureCallback onGestureFired,
  required VoidCallback onHandDetected,
  required StatusCallback onTrainingCompleted,
  bool patientExecutionMode = false,
}) {
  return _WebStudioView(
    onGestureFired: onGestureFired,
    onHandDetected: onHandDetected,
    onTrainingCompleted: onTrainingCompleted,
    patientExecutionMode: patientExecutionMode,
  );
}

class _WebStudioView extends StatefulWidget {
  const _WebStudioView({
    required this.onGestureFired,
    required this.onHandDetected,
    required this.onTrainingCompleted,
    required this.patientExecutionMode,
  });

  final GestureCallback onGestureFired;
  final VoidCallback onHandDetected;
  final StatusCallback onTrainingCompleted;
  final bool patientExecutionMode;

  @override
  State<_WebStudioView> createState() => _WebStudioViewState();
}

class _WebStudioViewState extends State<_WebStudioView> {
  String get _viewType =>
      widget.patientExecutionMode ? _patientViewType : _calibrationViewType;
  StreamSubscription<html.MessageEvent>? _messageSub;

  @override
  void initState() {
    super.initState();
    final viewType = _viewType;
    if (_registeredViews.add(viewType)) {
      ui_web.platformViewRegistry.registerViewFactory(viewType, (int viewId) {
        final base = html.document.baseUri ?? html.window.location.href;
        final relativePath = widget.patientExecutionMode
            ? 'assets/assets/web/fingerspeak_studio.html?patientMode=1'
            : 'assets/assets/web/fingerspeak_studio.html';
        final src = Uri.parse(base).resolve(relativePath).toString();
        final iframe = html.IFrameElement()
          ..src = src
          ..style.border = 'none'
          ..style.width = '100%'
          ..style.height = '100%'
          ..setAttribute(
              'allow', 'camera *; microphone *; autoplay; fullscreen; display-capture *')
          ..setAttribute('allowfullscreen', 'true')
          ..allow = 'camera; microphone; autoplay; display-capture';
        return iframe;
      });
    }

    _messageSub = html.window.onMessage.listen((event) {
      try {
        final raw = event.data;
        if (raw is String) {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          final type = data['type'] as String?;
          if (type == 'gesture_fired') {
            final g = data['gesture'] as String? ?? '';
            final p = data['phrase'] as String? ?? '';
            final c = (data['confidence'] as num?)?.toDouble() ?? 0.85;
            widget.onGestureFired(g, p, c);
          } else if (type == 'hand_detected') {
            widget.onHandDetected();
          } else if (type == 'training_completed') {
            final s = data['accSummary'] as String? ?? 'Training complete';
            widget.onTrainingCompleted(s);
          }
        }
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
