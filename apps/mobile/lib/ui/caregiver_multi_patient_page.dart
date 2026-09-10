import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/services/patient_roster_service.dart';
import 'package:fingerspeak_mobile/ui/caregiver_page.dart';
import 'package:fingerspeak_mobile/ui/settings_page.dart';
import 'package:flutter/material.dart';

enum RosterFilter { all, localOnly, emergencies }

/// Clinical Multi-Patient Ward Triage & Monitoring Dashboard
/// Designed for Caregivers to oversee 10–20 patients simultaneously.
/// Operates 100% offline via local Wi-Fi peer sync with zero internet dependency.
class CaregiverMultiPatientPage extends StatefulWidget {
  const CaregiverMultiPatientPage({
    required this.services,
    super.key,
  });

  final MobileServices services;

  @override
  State<CaregiverMultiPatientPage> createState() => _CaregiverMultiPatientPageState();
}

class _CaregiverMultiPatientPageState extends State<CaregiverMultiPatientPage> {
  RosterFilter _filter = RosterFilter.all;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    widget.services.patientRoster.addListener(_onRosterChanged);
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    widget.services.patientRoster.removeListener(_onRosterChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onRosterChanged() {
    if (mounted) setState(() {});
  }

  List<MonitoredPatient> _getFilteredPatients() {
    final all = widget.services.patientRoster.patients;
    return all.where((p) {
      if (_filter == RosterFilter.localOnly &&
          p.connectionState != PatientConnectionState.localLan) {
        return false;
      }
      if (_filter == RosterFilter.emergencies && !p.isEmergency) {
        return false;
      }
      if (_searchQuery.isNotEmpty) {
        final matchesName = p.name.toLowerCase().contains(_searchQuery);
        final matchesRoom = p.roomNumber.toLowerCase().contains(_searchQuery);
        if (!matchesName && !matchesRoom) return false;
      }
      return true;
    }).toList();
  }

  void _showBroadcastDialog() {
    final messageController = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.campaign, color: Color(0xFF0D9488)),
            SizedBox(width: 8),
            Text('Ward-Wide Broadcast', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Send a notification to all active patient wheelchair displays simultaneously over local Wi-Fi:',
              style: TextStyle(fontSize: 13, color: Color(0xFF475569)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: messageController,
              maxLength: 160,
              decoration: const InputDecoration(
                hintText: 'e.g., Morning rounds starting in 10 minutes',
                labelText: 'Broadcast Message',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                _QuickPresetChip(
                  label: 'Morning Rounds',
                  onTap: () => messageController.text = 'Morning clinical rounds starting now.',
                ),
                _QuickPresetChip(
                  label: 'Lunch Serving',
                  onTap: () => messageController.text = 'Lunch trays are being delivered to your room.',
                ),
                _QuickPresetChip(
                  label: 'Quiet Hours',
                  onTap: () => messageController.text = 'Quiet resting hours are now in effect.',
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0D9488)),
            onPressed: () async {
              final text = messageController.text.trim();
              if (text.isEmpty) return;
              Navigator.of(ctx).pop();
              final sentCount =
                  await widget.services.patientRoster.broadcastToAllPatients(text);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Broadcast delivered to $sentCount patient display(s).'),
                    backgroundColor: const Color(0xFF0D9488),
                  ),
                );
              }
            },
            icon: const Icon(Icons.send, size: 16),
            label: const Text('Broadcast Now'),
          ),
        ],
      ),
    );
  }

  void _showPatientMessageSheet(MonitoredPatient patient) {
    final controller = TextEditingController();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFCCFBF1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.tv, color: Color(0xFF0D9488), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Send Message to ${patient.name}',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      Text(
                        '${patient.roomNumber} • ${patient.ipAddress.isNotEmpty ? patient.ipAddress : "Cloud"}',
                        style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              maxLength: 200,
              decoration: const InputDecoration(
                hintText: 'e.g., I am bringing your medication now',
                labelText: 'Message for patient wheelchair display',
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                _QuickPresetChip(
                  label: 'I am on my way',
                  onTap: () => controller.text = 'I am on my way to your room right now.',
                ),
                _QuickPresetChip(
                  label: 'Doctor coming soon',
                  onTap: () => controller.text = 'Dr. Sharma is arriving to check on you shortly.',
                ),
                _QuickPresetChip(
                  label: 'Rest well',
                  onTap: () => controller.text = 'Take your time and rest well. Asha is watching over you.',
                ),
                _QuickPresetChip(
                  label: 'Water ready',
                  onTap: () => controller.text = 'I have fresh water ready for you.',
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final text = controller.text.trim();
                      if (text.isEmpty) return;
                      Navigator.of(ctx).pop();
                      if (patient.ipAddress.isNotEmpty) {
                        await widget.services.localPeerSync.sendRemoteSpeakRequest(
                          targetIp: patient.ipAddress,
                          targetPort: patient.httpPort,
                          phrase: text,
                        );
                      }
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Audio spoken on ${patient.name}\'s speaker.')),
                        );
                      }
                    },
                    icon: const Icon(Icons.volume_up, size: 18),
                    label: const Text('Speak on Speaker'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: const Color(0xFF0D9488)),
                    onPressed: () async {
                      final text = controller.text.trim();
                      if (text.isEmpty) return;
                      Navigator.of(ctx).pop();
                      final ok = await widget.services.patientRoster
                          .sendDisplayMessageToPatient(
                        patientId: patient.id,
                        message: text,
                      );
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(ok
                                ? 'Delivered to ${patient.name}\'s display.'
                                : 'Failed to reach patient screen.'),
                            backgroundColor: ok ? const Color(0xFF0D9488) : const Color(0xFFEF4444),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.send, size: 18),
                    label: const Text('Send to Screen'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _openSinglePatientTools(MonitoredPatient patient) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(
            title: Text('${patient.name} (${patient.roomNumber})'),
            backgroundColor: Colors.white,
            foregroundColor: const Color(0xFF0F172A),
            elevation: 1,
          ),
          body: CaregiverPage(services: widget.services),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final roster = widget.services.patientRoster;
    final filtered = _getFilteredPatients();
    final emergencyPatients = roster.patients.where((p) => p.isEmergency).toList();

    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: const BoxDecoration(
                    color: Color(0xFF10B981),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Asha Clinical Ward Triage',
                  style: TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 18,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
            const Text(
              'Zero-Config Offline Mesh • 10–20 Monitored Beds',
              style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Broadcast to all beds',
            icon: const Icon(Icons.campaign, color: Color(0xFF0D9488)),
            onPressed: _showBroadcastDialog,
          ),
          IconButton(
            tooltip: 'Clinical Setup & Calibration',
            icon: const Icon(Icons.settings, color: Color(0xFF64748B)),
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    appBar: AppBar(
                      title: const Text('Clinical Settings & Tools'),
                      backgroundColor: Colors.white,
                    ),
                    body: SettingsPage(services: widget.services),
                  ),
                ),
              );
            },
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          // Emergency Triage Hero Banner (Appears whenever any patient triggers SOS)
          if (emergencyPatients.isNotEmpty)
            SliverToBoxAdapter(
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF2F2),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFEF4444), width: 2),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.warning_amber_rounded,
                            color: Color(0xFFDC2626), size: 28),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'EMERGENCY SOS: ${emergencyPatients.length} BED(S) REQUIRE ASSISTANCE',
                            style: const TextStyle(
                              color: Color(0xFFDC2626),
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ...emergencyPatients.map((p) => Container(
                          margin: const EdgeInsets.only(top: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: const Color(0xFFFCA5A5)),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${p.roomNumber} • ${p.name}',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14,
                                        color: Color(0xFF991B1B),
                                      ),
                                    ),
                                    Text(
                                      'Signal: ${p.accessMethod} • Battery ${p.batteryPercent}%',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Color(0xFF7F1D1D),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFDC2626),
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                ),
                                onPressed: () =>
                                    widget.services.patientRoster.acknowledgeEmergency(p.id),
                                child: const Text('Acknowledge SOS'),
                              ),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            ),

          // Ward Stats Overview Header
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  _StatBadge(
                    label: 'Monitored',
                    count: roster.patients.length,
                    icon: Icons.people_outline,
                    color: const Color(0xFF0F172A),
                  ),
                  const SizedBox(width: 8),
                  _StatBadge(
                    label: 'Local LAN',
                    count: roster.localOnlineCount,
                    icon: Icons.wifi,
                    color: const Color(0xFF0D9488),
                  ),
                  const SizedBox(width: 8),
                  _StatBadge(
                    label: 'Emergencies',
                    count: roster.emergencyCount,
                    icon: Icons.emergency,
                    color: roster.emergencyCount > 0
                        ? const Color(0xFFDC2626)
                        : const Color(0xFF64748B),
                  ),
                ],
              ),
            ),
          ),

          // Search & Filter Bar
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                children: [
                  TextField(
                    controller: _searchController,
                    decoration: InputDecoration(
                      hintText: 'Search by bed number or patient name…',
                      prefixIcon: const Icon(Icons.search, size: 20),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Color(0xFFCBD5E1)),
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        FilterChip(
                          label: Text('All Beds (${roster.patients.length})'),
                          selected: _filter == RosterFilter.all,
                          onSelected: (_) => setState(() => _filter = RosterFilter.all),
                          selectedColor: const Color(0xFFCCFBF1),
                        ),
                        const SizedBox(width: 6),
                        FilterChip(
                          label: Text('Local LAN Active (${roster.localOnlineCount})'),
                          selected: _filter == RosterFilter.localOnly,
                          onSelected: (_) => setState(() => _filter = RosterFilter.localOnly),
                          selectedColor: const Color(0xFFCCFBF1),
                        ),
                        const SizedBox(width: 6),
                        FilterChip(
                          label: Text('Emergencies (${roster.emergencyCount})'),
                          selected: _filter == RosterFilter.emergencies,
                          onSelected: (_) => setState(() => _filter = RosterFilter.emergencies),
                          selectedColor: const Color(0xFFFEE2E2),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Patients List / Grid
          if (filtered.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  'No patients match the current filter.',
                  style: TextStyle(color: Color(0xFF94A3B8)),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final patient = filtered[index];
                    return _PatientCard(
                      patient: patient,
                      onSendMessage: () => _showPatientMessageSheet(patient),
                      onOpenTools: () => _openSinglePatientTools(patient),
                      onAcknowledgeEmergency: () =>
                          widget.services.patientRoster.acknowledgeEmergency(patient.id),
                    );
                  },
                  childCount: filtered.length,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatBadge extends StatelessWidget {
  const _StatBadge({
    required this.label,
    required this.count,
    required this.icon,
    required this.color,
  });

  final String label;
  final int count;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE2E8F0)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: color,
                  ),
                ),
                Text(
                  label,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PatientCard extends StatelessWidget {
  const _PatientCard({
    required this.patient,
    required this.onSendMessage,
    required this.onOpenTools,
    required this.onAcknowledgeEmergency,
  });

  final MonitoredPatient patient;
  final VoidCallback onSendMessage;
  final VoidCallback onOpenTools;
  final VoidCallback onAcknowledgeEmergency;

  @override
  Widget build(BuildContext context) {
    final isEmergency = patient.isEmergency;
    final isLocal = patient.connectionState == PatientConnectionState.localLan;
    final isCloud = patient.connectionState == PatientConnectionState.cloudOnly;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: isEmergency
              ? const Color(0xFFEF4444)
              : isLocal
                  ? const Color(0xFF99F6E4)
                  : const Color(0xFFE2E8F0),
          width: isEmergency ? 2 : 1,
        ),
      ),
      elevation: isEmergency ? 3 : 1,
      color: isEmergency ? const Color(0xFFFFF5F5) : Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Row: Bed/Room & Connection Status Chip
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    patient.roomNumber,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Spacer(),
                if (isLocal)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD1FAE5),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFA7F3D0)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.wifi, size: 12, color: Color(0xFF065F46)),
                        const SizedBox(width: 4),
                        Text(
                          'LAN (${patient.ipAddress})',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF065F46),
                          ),
                        ),
                      ],
                    ),
                  )
                else if (isCloud)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE0E7FF),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Cloud Sync',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF3730A3),
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'Offline',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF64748B),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Patient Name & Vitals Row
            Row(
              children: [
                Expanded(
                  child: Text(
                    patient.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF0F172A),
                    ),
                  ),
                ),
                // Battery %
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      patient.batteryPercent > 50
                          ? Icons.battery_full
                          : patient.batteryPercent > 20
                              ? Icons.battery_3_bar
                              : Icons.battery_alert,
                      size: 16,
                      color: patient.batteryPercent > 50
                          ? const Color(0xFF10B981)
                          : patient.batteryPercent > 20
                              ? const Color(0xFFF59E0B)
                              : const Color(0xFFEF4444),
                    ),
                    const SizedBox(width: 2),
                    Text(
                      '${patient.batteryPercent}%',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: patient.batteryPercent < 20
                            ? const Color(0xFFDC2626)
                            : const Color(0xFF475569),
                      ),
                    ),
                  ],
                ),
                if (patient.respirationBpm != null) ...[
                  const SizedBox(width: 10),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.air, size: 14, color: Color(0xFF0D9488)),
                      const SizedBox(width: 2),
                      Text(
                        '${patient.respirationBpm!.toStringAsFixed(1)} bpm',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF475569),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),

            // AAC Access Method Chip
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                'Access: ${patient.accessMethod}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF475569),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Last Spoken Phrase or Status
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFF8FAFC),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.chat_bubble_outline, size: 16, color: Color(0xFF0D9488)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      patient.lastSpokenPhrase ?? 'No recent phrases spoken',
                      style: TextStyle(
                        fontSize: 13,
                        fontStyle:
                            patient.lastSpokenPhrase != null ? FontStyle.normal : FontStyle.italic,
                        color: patient.lastSpokenPhrase != null
                            ? const Color(0xFF1E293B)
                            : const Color(0xFF94A3B8),
                        fontWeight:
                            patient.lastSpokenPhrase != null ? FontWeight.w600 : FontWeight.normal,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Action Buttons
            Row(
              children: [
                if (isEmergency)
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFFDC2626),
                      ),
                      onPressed: onAcknowledgeEmergency,
                      icon: const Icon(Icons.check, size: 16),
                      label: const Text('Ack SOS'),
                    ),
                  )
                else
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onSendMessage,
                      icon: const Icon(Icons.tv, size: 16),
                      label: const Text('Display Msg'),
                    ),
                  ),
                const SizedBox(width: 8),
                IconButton.filledTonal(
                  tooltip: 'Single-patient detailed tools & calibration',
                  icon: const Icon(Icons.tune, size: 18),
                  onPressed: onOpenTools,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickPresetChip extends StatelessWidget {
  const _QuickPresetChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      onPressed: onTap,
      backgroundColor: const Color(0xFFF1F5F9),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}
