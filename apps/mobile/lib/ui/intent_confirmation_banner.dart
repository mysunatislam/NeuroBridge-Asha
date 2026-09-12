// intent_confirmation_banner.dart
// Shows the Confidence Verification Engine's state on the patient screen:
// a pending "Did you mean help?" prompt with touch Yes/No (the patient can also
// confirm with their confirm gesture), the last verified command, and
// abnormal-movement alerts.

import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/intent/intent_recognition_service.dart';
import 'package:flutter/material.dart';

class IntentConfirmationBanner extends StatefulWidget {
  const IntentConfirmationBanner({required this.services, super.key});

  final MobileServices services;

  @override
  State<IntentConfirmationBanner> createState() => _IntentConfirmationBannerState();
}

class _IntentConfirmationBannerState extends State<IntentConfirmationBanner> {
  StreamSubscription<IntentDecisionEvent>? _subscription;
  IntentDecisionEvent? _last;
  Timer? _clearTimer;

  @override
  void initState() {
    super.initState();
    _subscription = widget.services.intentRecognition.events.listen((event) {
      if (!mounted) return;
      setState(() => _last = event);
      _clearTimer?.cancel();
      _clearTimer = Timer(const Duration(seconds: 12), () {
        if (mounted && _last?.kind != IntentDecisionKind.confirmationRequested) {
          setState(() => _last = null);
        }
      });
    });
  }

  @override
  void dispose() {
    _clearTimer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final intent = widget.services.intentRecognition;
    return ListenableBuilder(
      listenable: intent,
      builder: (context, _) {
        if (!intent.enabled) return const SizedBox.shrink();
        if (intent.hasPendingConfirmation) {
          final command = (intent.pendingCommand ?? '').replaceAll('_', ' ');
          final prompt = _last?.prompt ?? 'Did you mean $command?';
          return Card(
            color: const Color(0xFFFFFBEB),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: Color(0xFFF59E0B)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.help_outline, color: Color(0xFFB45309)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(prompt,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Confidence ${((_last?.confidence ?? 0) * 100).round()} %. '
                    'Repeat the movement, use your confirm gesture, or tap.',
                    style: const TextStyle(color: Color(0xFF64748B)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: intent.confirmPendingByTouch,
                          icon: const Icon(Icons.check),
                          label: const Text('Yes'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: intent.cancelPending,
                          icon: const Icon(Icons.close),
                          label: const Text('No'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }
        final last = _last;
        if (last == null) return const SizedBox.shrink();
        final (color, icon, text) = switch (last.kind) {
          IntentDecisionKind.executed => (
              const Color(0xFFCCFBF1),
              Icons.check_circle_outline,
              'Understood: ${last.command.replaceAll('_', ' ')} '
                  '(${(last.confidence * 100).round()} %)',
            ),
          IntentDecisionKind.alert => (
              const Color(0xFFFEE2E2),
              Icons.warning_amber_rounded,
              'Possible involuntary movement detected. Commands paused; caregiver notified.',
            ),
          IntentDecisionKind.cancelled => (
              const Color(0xFFE2E8F0),
              Icons.timer_off_outlined,
              'No confirmation received; nothing was sent.',
            ),
          IntentDecisionKind.confirmationRequested => (
              const Color(0xFFFFFBEB),
              Icons.help_outline,
              last.prompt ?? 'Please confirm.',
            ),
        };
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(12)),
            child: Row(
              children: [
                Icon(icon, color: const Color(0xFF0F172A)),
                const SizedBox(width: 10),
                Expanded(child: Text(text, style: const TextStyle(fontWeight: FontWeight.w600))),
              ],
            ),
          ),
        );
      },
    );
  }
}
