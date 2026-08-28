import 'dart:async';

import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/ui/asha_chat_sheet.dart';
import 'package:fingerspeak_mobile/ui/caregiver_page.dart';
import 'package:fingerspeak_mobile/ui/effects/angelic_sparkle.dart';
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
          seedColor: const Color(0xFF0B756A),
          primary: const Color(0xFF0B756A),
          secondary: const Color(0xFFFFD166),
          surface: const Color(0xFF0F1720),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF0A1119),
        useMaterial3: true,
        fontFamily: 'Space Grotesk',
        textTheme: const TextTheme(
          headlineMedium: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
          titleLarge: TextStyle(fontWeight: FontWeight.w800, color: Colors.white),
          titleMedium: TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
          bodyMedium: TextStyle(color: Color(0xFFE0E6ED)),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          filled: true,
          fillColor: Color(0xFF161F29),
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
              backgroundColor: Color(0xFF0A1119),
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF4FD1C5)),
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

  @override
  void initState() {
    super.initState();
    _activeRole = widget.services.roleRepository.load();
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
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_activeRole == null) {
      return RoleSelectionPage(
        services: widget.services,
        onRoleSelected: (role) => setState(() => _activeRole = role),
      );
    }
    return MobileHome(
      services: widget.services,
      initialRole: _activeRole!,
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A1119),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 52, color: Color(0xFFE86A6A)),
              const SizedBox(height: 16),
              Text(
                'NeuroBridge Asha could not start',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(color: Colors.white),
              ),
              const SizedBox(height: 12),
              Text('$error', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF8CA0A8))),
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
      backgroundColor: const Color(0xFF0A1119),
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: [
            PatientPage(services: services, isActive: _index == 0),
            CaregiverPage(services: services),
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
      bottomNavigationBar: NavigationBar(
        backgroundColor: const Color(0xFF101923),
        indicatorColor: const Color(0xFF1E3836),
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.favorite_outline, color: Color(0xFF8CA0A8)),
            selectedIcon: Icon(Icons.favorite, color: Color(0xFF4FD1C5)),
            label: 'Patient',
          ),
          NavigationDestination(
            icon: Icon(Icons.people_outline, color: Color(0xFF8CA0A8)),
            selectedIcon: Icon(Icons.people, color: Color(0xFFE992A4)),
            label: 'Caregiver',
          ),
          NavigationDestination(
            icon: Icon(Icons.tv_outlined, color: Color(0xFF8CA0A8)),
            selectedIcon: Icon(Icons.tv, color: Color(0xFFFFD166)),
            label: 'Wheelchair Display',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined, color: Color(0xFF8CA0A8)),
            selectedIcon: Icon(Icons.settings, color: Color(0xFF4FD1C5)),
            label: 'Setup',
          ),
        ],
      ),
    );
  }
}
