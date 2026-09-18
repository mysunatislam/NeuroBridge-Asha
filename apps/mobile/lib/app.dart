import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/caregiver_page.dart';
import 'package:fingerspeak_mobile/ui/effects/angelic_sparkle.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:fingerspeak_mobile/ui/patient_page.dart';
import 'package:fingerspeak_mobile/ui/pi_display_page.dart';
import 'package:fingerspeak_mobile/ui/role_selection_page.dart';
import 'package:fingerspeak_mobile/ui/settings_page.dart';
import 'package:fingerspeak_mobile/ui/caregiver_multi_patient_page.dart';
import 'package:fingerspeak_mobile/ui/effects/liquid_glass.dart';
import 'package:flutter/material.dart';

class FingerSpeakMobileApp extends StatefulWidget {
  const FingerSpeakMobileApp({
    super.key,
    this.services,
    this.forcedRole,
  });

  final MobileServices? services;
  final UserRole? forcedRole;

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
    return ValueListenableBuilder<bool>(
      valueListenable: LiquidGlassThemeController.isDarkNotifier,
      builder: (context, isDark, _) {
        return MaterialApp(
          title: 'NeuroBridge Asha',
          debugShowCheckedModeBanner: false,
          themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
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
              headlineMedium: TextStyle(
                  fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
              titleLarge: TextStyle(
                  fontWeight: FontWeight.w800, color: Color(0xFF0F172A)),
              titleMedium: TextStyle(
                  fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
              bodyMedium: TextStyle(color: Color(0xFF334155)),
            ),
            inputDecorationTheme: InputDecorationTheme(
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF0D9488),
              primary: const Color(0xFF2DD4BF),
              secondary: const Color(0xFFF59E0B),
              surface: const Color(0xFF0D1527),
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF070A12),
            useMaterial3: true,
            fontFamily: 'Space Grotesk',
            cardTheme: CardThemeData(
              color: const Color(0x281E293B),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0x3838BDF8)),
              ),
            ),
            textTheme: const TextTheme(
              headlineMedium: TextStyle(
                  fontWeight: FontWeight.w800, color: Color(0xFFF8FAFC)),
              titleLarge: TextStyle(
                  fontWeight: FontWeight.w800, color: Color(0xFFF8FAFC)),
              titleMedium: TextStyle(
                  fontWeight: FontWeight.w700, color: Color(0xFFE2E8F0)),
              bodyMedium: TextStyle(color: Color(0xFF94A3B8)),
            ),
            navigationBarTheme: NavigationBarThemeData(
              backgroundColor: const Color(0xFF0D1527),
              indicatorColor: const Color(0x332DD4BF),
              iconTheme: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return const IconThemeData(color: Color(0xFF2DD4BF));
                }
                return const IconThemeData(color: Color(0xFF94A3B8));
              }),
              labelTextStyle: WidgetStateProperty.resolveWith((states) {
                if (states.contains(WidgetState.selected)) {
                  return const TextStyle(
                      color: Color(0xFF2DD4BF), fontWeight: FontWeight.bold);
                }
                return const TextStyle(color: Color(0xFF94A3B8));
              }),
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
                  services: services,
                  onFinished: () {
                    if (mounted) setState(() => _splashCompleted = true);
                  },
                );
              }

              return _AppRoot(
                services: services,
                forcedRole: widget.forcedRole,
              );
            },
          ),
        );
      },
    );
  }
}

class _AppRoot extends StatefulWidget {
  const _AppRoot({
    required this.services,
    this.forcedRole,
  });

  final MobileServices services;
  final UserRole? forcedRole;

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
    _activeRole = widget.forcedRole ?? widget.services.roleRepository.load();
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
      setState(() => _activeRole =
          widget.forcedRole ?? widget.services.roleRepository.load());
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
    if (widget.forcedRole == UserRole.caregiver) {
      return CaregiverMultiPatientPage(services: widget.services);
    }

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
        forcedRole: widget.forcedRole,
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
    this.forcedRole,
    super.key,
  });

  final MobileServices services;
  final UserRole initialRole;
  final UserRole? forcedRole;

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
    final isPatientOnly = widget.forcedRole == UserRole.patient;
    final isDark = LiquidGlassThemeController.isDark;
    final navBgColor = isDark ? const Color(0xFF0D1527) : Colors.white;
    final navBorderColor =
        isDark ? const Color(0x3338BDF8) : const Color(0xFFE2E8F0);
    final navIndicator =
        isDark ? const Color(0x332DD4BF) : const Color(0xFFCCFBF1);

    if (isPatientOnly) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _index.clamp(0, 2),
            children: [
              PatientPage(services: services, isActive: _index == 0),
              PiDisplayPage(services: services),
              SettingsPage(
                services: services,
                onRoleChanged: (_) {},
              ),
            ],
          ),
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: navBgColor,
            border: Border(top: BorderSide(color: navBorderColor)),
          ),
          child: NavigationBar(
            backgroundColor: navBgColor,
            elevation: 0,
            indicatorColor: navIndicator,
            selectedIndex: _index.clamp(0, 2),
            onDestinationSelected: (index) => setState(() => _index = index),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.favorite_outline, color: Color(0xFF64748B)),
                selectedIcon: Icon(Icons.favorite, color: Color(0xFF0D9488)),
                label: 'Asha Patient',
              ),
              NavigationDestination(
                icon: Icon(Icons.tv_outlined, color: Color(0xFF64748B)),
                selectedIcon: Icon(Icons.tv, color: Color(0xFFD97706)),
                label: 'Wheelchair Display',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined, color: Color(0xFF64748B)),
                selectedIcon: Icon(Icons.settings, color: Color(0xFF0D9488)),
                label: 'Setup & Voice',
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: navBgColor,
          border: Border(top: BorderSide(color: navBorderColor)),
        ),
        child: NavigationBar(
          backgroundColor: navBgColor,
          elevation: 0,
          indicatorColor: navIndicator,
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
