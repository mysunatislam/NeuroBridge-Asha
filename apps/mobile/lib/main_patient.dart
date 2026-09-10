import 'dart:async';
import 'package:fingerspeak_mobile/app.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/local_peer_sync_service.dart';
import 'package:flutter/material.dart';

/// Dedicated entry point for the NeuroBridge Asha Patient App.
/// Starts continuous background voice monitoring, UDP broadcast beacons on port 41528,
/// embedded HTTP server on port 41529 for remote display, and direct SOS alerting.
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await MobileServices.create();

  // Start zero-config offline peer-to-peer sync in Patient mode
  unawaited(
    services.localPeerSync.startPatientMode(
      beaconProvider: () => AshaPatientBeacon(
        patientId: 'patient-bed-101',
        name: 'Eleanor Vance',
        roomNumber: 'Bed 101 (ICU East)',
        status: services.monitor.currentStatus.lifecycle.name,
        batteryPercent: 95,
        accessMethod: services.patientAccessMethodRepository.load()?.name ??
            '3D Hand Gestures',
        ipAddress: '',
        httpPort: 41529,
        timestamp: DateTime.now(),
        respirationBpm: 16.2,
        lastSpokenPhrase: services.recognition.phrases.isNotEmpty
            ? services.recognition.phrases.first.phrase
            : null,
      ),
    ),
  );

  runApp(
    FingerSpeakMobileApp(
      services: services,
      forcedRole: UserRole.patient,
    ),
  );
}
