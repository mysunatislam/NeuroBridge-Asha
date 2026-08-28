import 'package:flutter/material.dart';

typedef GestureCallback = void Function(
    String gesture, String phrase, double confidence);
typedef StatusCallback = void Function(String message);

Widget buildPlatformStudio({
  required BuildContext context,
  required GestureCallback onGestureFired,
  required VoidCallback onHandDetected,
  required StatusCallback onTrainingCompleted,
  bool patientExecutionMode = false,
}) {
  return const Center(child: Text('Platform not supported'));
}
