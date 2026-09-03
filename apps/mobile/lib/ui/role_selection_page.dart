import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/user_role.dart';
import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:fingerspeak_mobile/ui/guide/asha_guide_host.dart';
import 'package:flutter/material.dart';

class RoleSelectionPage extends StatefulWidget {
  const RoleSelectionPage({
    required this.services,
    required this.onRoleSelected,
    super.key,
  });

  final MobileServices services;
  final void Function(UserRole role) onRoleSelected;

  @override
  State<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends State<RoleSelectionPage> {
  UserRole? _selectedRole;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedRole = widget.services.roleRepository.load();
  }

  Future<void> _proceed() async {
    final role = _selectedRole;
    if (role == null || _saving) return;
    setState(() => _saving = true);
    await widget.services.roleRepository.save(role);
    if (mounted) {
      widget.onRoleSelected(role);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F1E8),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white,
                        border: Border.all(
                            color: const Color(0xFF0B756A), width: 3),
                        boxShadow: const [
                          BoxShadow(
                            blurRadius: 16,
                            offset: Offset(0, 4),
                            color: Color(0x22000000),
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Image.asset(
                        'assets/images/asha-avatar.webp',
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                          Icons.face,
                          size: 48,
                          color: Color(0xFF0B756A),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'NEUROBRIDGE ASHA',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: const Color(0xFF0B756A),
                          letterSpacing: 2.0,
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Who is using this device?',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          color: const Color(0xFF102522),
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Choose your mode. You can easily switch anytime in Setup.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF5A706A), fontSize: 15),
                  ),
                  const SizedBox(height: 32),
                  AshaGuideTarget(
                    step: AshaGuideStep.role,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _RoleOptionCard(
                          role: UserRole.patient,
                          isSelected: _selectedRole == UserRole.patient,
                          icon: Icons.accessible_forward,
                          title: 'I am a Patient',
                          subtitle:
                              'Speak with eye gaze, facial expressions, or hand gestures. Asha companion stays with you and reassures you.',
                          accentColor: const Color(0xFF0B756A),
                          onTap: () =>
                              setState(() => _selectedRole = UserRole.patient),
                        ),
                        const SizedBox(height: 16),
                        _RoleOptionCard(
                          role: UserRole.caregiver,
                          isSelected: _selectedRole == UserRole.caregiver,
                          icon: Icons.volunteer_activism,
                          title: 'I am a Caregiver',
                          subtitle:
                              'Step-by-step patient signal calibration, live speech & distress alerts, wheelchair display writing, and emergency guides.',
                          accentColor: const Color(0xFFC04B67),
                          onTap: () =>
                              setState(() => _selectedRole = UserRole.caregiver),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),
                  AshaGuideTarget(
                    step: AshaGuideStep.profile,
                    child: SizedBox(
                      height: 56,
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFF0B756A),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        onPressed:
                            _selectedRole == null || _saving ? null : _proceed,
                        icon: const Icon(Icons.arrow_forward),
                        label: Text(
                          _selectedRole == UserRole.patient
                              ? 'Open Patient Dashboard'
                              : _selectedRole == UserRole.caregiver
                                  ? 'Open Caregiver Dashboard'
                                  : 'Select a Mode to Continue',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoleOptionCard extends StatelessWidget {
  const _RoleOptionCard({
    required this.role,
    required this.isSelected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.onTap,
  });

  final UserRole role;
  final bool isSelected;
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accentColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(
        color: isSelected ? Colors.white : const Color(0xFFF0EAE1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isSelected ? accentColor : const Color(0xFFD6CEBF),
          width: isSelected ? 2.5 : 1.2,
        ),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                  color: accentColor.withValues(alpha: 0.18),
                ),
              ]
            : const [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: isSelected
                      ? accentColor.withValues(alpha: 0.15)
                      : const Color(0xFFE2DCD1),
                  child: Icon(icon,
                      color: isSelected ? accentColor : Colors.black54,
                      size: 30),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: isSelected
                                    ? accentColor
                                    : const Color(0xFF102522),
                              ),
                            ),
                          ),
                          if (isSelected)
                            Icon(Icons.check_circle,
                                color: accentColor, size: 24),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Color(0xFF4A5E59),
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
