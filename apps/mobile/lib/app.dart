import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/asha_chat_sheet.dart';
import 'package:fingerspeak_mobile/ui/caregiver_page.dart';
import 'package:fingerspeak_mobile/ui/effects/angelic_sparkle.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:fingerspeak_mobile/ui/patient_page.dart';
import 'package:fingerspeak_mobile/ui/pi_display_page.dart';
import 'package:fingerspeak_mobile/ui/role_selection_page.dart';
import 'package:fingerspeak_mobile/ui/settings_page.dart';
import 'package:flutter/material.dart';

class FingerSpeakMobileApp extends StatefulWidget {
  const FingerSpeakMobileApp({super.key, this.services});

  final MobileServices? services;

  @override
  State<FingerSpeakMobileApp> createState() => _FingerSpeakMobileAppState();
}

class _FingerSpeakMobileAppState extends State<FingerSpeakMobileApp> {
  late final Future<MobileServices> _services = widget.services == null
      ? MobileServices.create()
      : Future.value(widget.services!);

  bool _splashCompleted = false;

  @override
  void dispose() {
    if (widget.services == null) {
      unawaited(_services.then((services) => services.dispose()));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NeuroBridge Asha',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0D9488),
          primary: const Color(0xFF0D9488),
          secondary: const Color(0xFFD97706),
          surface: Colors.white,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF8FAFC),
        useMaterial3: true,
        fontFamily: 'Space Grotesk',
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
        ),
        textTheme: const TextTheme(
          headlineMedium:
              TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
          titleLarge:
              TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
          titleMedium:
              TextStyle(fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
          bodyMedium: TextStyle(color: Color(0xFF334155)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          filled: true,
          fillColor: Colors.white,
        ),
      ),
      home: FutureBuilder<MobileServices>(
        future: _services,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return _StartupError(error: snapshot.error!);
          }
          final services = snapshot.data;
          if (services == null) {
            return const Scaffold(
              backgroundColor: Color(0xFFF8FAFC),
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF0D9488)),
              ),
            );
          }

          if (!_splashCompleted) {
            return AngelicSparkleSplash(
              onFinished: () {
                if (mounted) setState(() => _splashCompleted = true);
              },
            );
          }

          return _AppRoot(services: services);
        },
      ),
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot({required this.services});

  final MobileServices services;

  @override
  State<_AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<_AppRoot> {
  UserRole? _activeRole;
  final GlobalKey<_MobileHomeState> _mobileHomeKey =
      GlobalKey<_MobileHomeState>();

  @override
  void initState() {
    super.initState();
    _activeRole = widget.services.roleRepository.load();
    unawaited(widget.services.ashaGuide.setRoleSelected(_activeRole != null));
    widget.services.roleRepository.addListener(_onRoleChanged);
  }

  @override
  void dispose() {
    widget.services.roleRepository.removeListener(_onRoleChanged);
    super.dispose();
  }

  void _onRoleChanged() {
    if (mounted) {
      setState(() => _activeRole = widget.services.roleRepository.load());
      _resumeGuideAfterRoleSelection();
    }
  }

  void _resumeGuideAfterRoleSelection() {
    final guide = widget.services.ashaGuide;
    unawaited(guide.setRoleSelected(_activeRole != null));
    if (_activeRole == null || !guide.isActive) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !guide.isActive) return;
      _mobileHomeKey.currentState?.revealGuideStep(guide.step);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget content;
    if (_activeRole == null) {
      content = RoleSelectionPage(
        services: widget.services,
        onRoleSelected: (role) {
          setState(() => _activeRole = role);
          _resumeGuideAfterRoleSelection();
        },
      );
    } else {
      content = MobileHome(
        key: _mobileHomeKey,
        services: widget.services,
        initialRole: _activeRole!,
      );
    }
    return AshaGuideHost(
      service: widget.services.ashaGuide,
      onNarrate: widget.services.voice.speakSystemPrompt,
      onRevealStep: (step) {
        _mobileHomeKey.currentState?.revealGuideStep(step);
      },
      child: content,
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  size: 52, color: Color(0xFFEF4444)),
              const SizedBox(height: 16),
              Text(
                'NeuroBridge Asha could not start',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    color: const Color(0xFF0F172A),
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text('$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF64748B))),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileHome extends StatefulWidget {
  const MobileHome({
    required this.services,
    this.initialRole = UserRole.patient,
    super.key,
  });

  final MobileServices services;
  final UserRole initialRole;

  @override
  State<MobileHome> createState() => _MobileHomeState();
}

class _MobileHomeState extends State<MobileHome> {
  late int _index = widget.initialRole == UserRole.caregiver ? 1 : 0;
  final GlobalKey<CaregiverPageState> _caregiverKey =
      GlobalKey<CaregiverPageState>();

  void revealGuideStep(AshaGuideStep step) {
    final nextIndex = switch (step) {
      AshaGuideStep.calibration || AshaGuideStep.report => 1,
      AshaGuideStep.profile || AshaGuideStep.firstSession => 0,
      _ => _index,
    };
    if (nextIndex != _index && mounted) setState(() => _index = nextIndex);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reveal = _caregiverKey.currentState?.revealGuideStep(step);
      if (reveal != null) unawaited(reveal);
    });
  }

  @override
  void didUpdateWidget(MobileHome oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRole != widget.initialRole) {
      _index = widget.initialRole == UserRole.caregiver ? 1 : 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = widget.services;
    final currentRole = _index == 1 ? UserRole.caregiver : UserRole.patient;

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: [
            PatientPage(services: services, isActive: _index == 0),
            CaregiverPage(key: _caregiverKey, services: services),
            PiDisplayPage(services: services),
            SettingsPage(
              services: services,
              onRoleChanged: (role) {
                setState(() => _index = role == UserRole.caregiver ? 1 : 0);
              },
            ),
          ],
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 72),
        child: AngelicAshaButton(
          isCaregiver: _index == 1,
          onTap: () => showAshaChatSheet(
            context,
            services.companion,
            role: currentRole,
            voiceService: services.voice,
            services: services,
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      bottomNavigationBar: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
        ),
        child: NavigationBar(
          backgroundColor: Colors.white,
          elevation: 0,
          indicatorColor: const Color(0xFFCCFBF1),
          selectedIndex: _index,
          onDestinationSelected: (index) => setState(() => _index = index),
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.favorite_outline, color: Color(0xFF64748B)),
              selectedIcon: Icon(Icons.favorite, color: Color(0xFF0D9488)),
              label: 'Patient',
            ),
            NavigationDestination(
              icon: Icon(Icons.people_outline, color: Color(0xFF64748B)),
              selectedIcon: Icon(Icons.people, color: Color(0xFFDB2777)),
              label: 'Caregiver',
            ),
            NavigationDestination(
              icon: Icon(Icons.tv_outlined, color: Color(0xFF64748B)),
              selectedIcon: Icon(Icons.tv, color: Color(0xFFD97706)),
              label: 'Wheelchair Display',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined, color: Color(0xFF64748B)),
              selectedIcon: Icon(Icons.settings, color: Color(0xFF0D9488)),
              label: 'Setup',
            ),
          ],
        ),
      ),
    );
  }
}
