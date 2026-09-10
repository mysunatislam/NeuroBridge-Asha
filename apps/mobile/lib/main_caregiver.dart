import 'dart:async';
import 'package:fingerspeak_mobile/app.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:flutter/material.dart';

/// Dedicated entry point for the NeuroBridge Asha Caregiver App.
/// Starts continuous offline UDP discovery listener on port 41528,
/// multi-patient triage roster (10–20 monitored patients),
/// wheelchair display broadcasting, and real-time emergency alerting.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await MobileServices.create();

  // Start continuous caregiver UDP listener to discover and sync all patients on local Wi-Fi
  unawaited(services.localPeerSync.startCaregiverListener());

  runApp(
    FingerSpeakMobileApp(
      services: services,
      forcedRole: UserRole.caregiver,
    ),
  );
}
