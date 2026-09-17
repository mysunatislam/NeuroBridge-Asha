import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:fingerspeak_mobile/core/mobile_services.dart';
import 'package:fingerspeak_mobile/models/patient_record.dart';

Future<void> showDoctorReportSheet({
  required BuildContext context,
  required MobileServices services,
  required PatientRecord patient,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => _DoctorReportSheet(
      services: services,
      patient: patient,
    ),
  );
}

class _DoctorReportSheet extends StatefulWidget {
  const _DoctorReportSheet({
    required this.services,
    required this.patient,
  });

  final MobileServices services;
  final PatientRecord patient;

  @override
  State<_DoctorReportSheet> createState() => _DoctorReportSheetState();
}

class _DoctorReportSheetState extends State<_DoctorReportSheet> {
  DoctorReportSummary? _report;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    setState(() => _generating = true);
    final rep = await widget.services.patientRegistry.generateDoctorReport(widget.patient.id);
    if (mounted) {
      setState(() {
        _report = rep;
        _generating = false;
      });
    }
  }

  Future<void> _sendSms() async {
    final phone = widget.patient.doctorPhone.replaceAll(' ', '');
    final summary = _report?.summaryText ?? '';
    final uri = Uri(
      scheme: 'sms',
      path: phone,
      queryParameters: {'body': summary.length > 300 ? '${summary.substring(0, 300)}... (See full NeuroBridge portal)' : summary},
    );
    try {
      if (!await launchUrl(uri)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not launch SMS app.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open SMS: $e')),
        );
      }
    }
  }

  Future<void> _sendEmail() async {
    final email = widget.patient.doctorEmail;
    final summary = _report?.summaryText ?? '';
    final uri = Uri(
      scheme: 'mailto',
      path: email,
      queryParameters: {
        'subject': 'NeuroBridge Clinical Progress Report - ${widget.patient.name}',
        'body': summary,
      },
    );
    try {
      if (!await launchUrl(uri)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not launch email app.')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not open email: $e')),
        );
      }
    }
  }

  void _copyToClipboard() {
    final summary = _report?.summaryText ?? '';
    Clipboard.setData(ClipboardData(text: summary));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Clinical report copied to clipboard.'),
        backgroundColor: Color(0xFF0B756A),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Drag handle
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 8),
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.black26,
              borderRadius: BorderRadius.circular(3),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              children: [
                const CircleAvatar(
                  backgroundColor: Color(0xFFE8F6F3),
                  child: Icon(Icons.medical_information, color: Color(0xFF0B756A)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Doctor Clinical Report',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      Text(
                        'Patient: ${widget.patient.name} • Attending: ${widget.patient.doctorName}',
                        style: const TextStyle(color: Color(0xFF556E68), fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          const Divider(height: 1),

          // Body
          Expanded(
            child: _generating
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('Compiling telemetry & clinical history...'),
                      ],
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // Doctor target card
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF8FAFC),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFE2E8F0)),
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.person_pin, color: Color(0xFF0B756A), size: 28),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.patient.doctorName,
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                  ),
                                  Text(
                                    '${widget.patient.doctorHospital}\n${widget.patient.doctorPhone} | ${widget.patient.doctorEmail}',
                                    style: const TextStyle(color: Color(0xFF64748B), fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Formatted report text container
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: SelectableText(
                          _report?.summaryText ?? '',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Color(0xFF1E293B),
                            height: 1.45,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),

          // Actions
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              color: Colors.white,
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _copyToClipboard,
                    icon: const Icon(Icons.copy, size: 18),
                    label: const Text('Copy'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _sendSms,
                    icon: const Icon(Icons.sms, size: 18),
                    label: const Text('SMS Doctor'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0B756A),
                    ),
                    onPressed: _sendEmail,
                    icon: const Icon(Icons.email, size: 18),
                    label: const Text('Email Doctor'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
