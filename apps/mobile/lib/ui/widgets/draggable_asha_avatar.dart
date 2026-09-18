import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/mobile_services.dart';
import '../asha_chat_sheet.dart';
import '../effects/liquid_glass.dart';

class DraggableAshaAvatar extends StatefulWidget {
  const DraggableAshaAvatar({
    required this.services,
    this.initialOffset = const Offset(24, 120),
    super.key,
  });

  final MobileServices services;
  final Offset initialOffset;

  @override
  State<DraggableAshaAvatar> createState() => _DraggableAshaAvatarState();
}

class _DraggableAshaAvatarState extends State<DraggableAshaAvatar>
    with SingleTickerProviderStateMixin {
  late Offset _position;
  late AnimationController _pulseController;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _position = widget.initialOffset;
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    final isTestEnvironment =
        WidgetsBinding.instance.runtimeType.toString().contains('Test');
    if (!isTestEnvironment) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final theme = LiquidGlassThemeData.current(context);

    const double avatarSize = 64.0;
    final maxLeft = math.max(0.0, screenSize.width - avatarSize - 16);
    final maxTop = math.max(0.0, screenSize.height - avatarSize - 80);

    // Clamp coordinates so it never goes off-screen
    final clampedX = _position.dx.clamp(12.0, maxLeft);
    final clampedY = _position.dy.clamp(60.0, maxTop);

    return Positioned(
      left: clampedX,
      top: clampedY,
      child: MouseRegion(
        cursor: _isDragging ? SystemMouseCursors.grabbing : SystemMouseCursors.click,
        child: GestureDetector(
          onPanStart: (_) {
            setState(() => _isDragging = true);
          },
          onPanUpdate: (details) {
            setState(() {
              _position += details.delta;
            });
          },
          onPanEnd: (_) {
            setState(() => _isDragging = false);
          },
          onTap: () {
            showAshaChatSheet(
              context,
              widget.services.companion,
              services: widget.services,
            );
          },
          child: AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              final glowRadius = 12.0 + (_pulseController.value * 10.0);

              return Container(
                width: avatarSize,
                height: avatarSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: theme.speakColor.withValues(alpha: 0.45),
                      blurRadius: glowRadius,
                      spreadRadius: _isDragging ? 4 : 2,
                    ),
                    BoxShadow(
                      color: const Color(0xFFC084FC).withValues(alpha: 0.3),
                      blurRadius: glowRadius * 1.4,
                      spreadRadius: 1,
                    ),
                  ],
                  border: Border.all(
                    color: _isDragging ? const Color(0xFF38BDF8) : const Color(0xFFC084FC),
                    width: 2.4,
                  ),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Avatar image
                    Positioned.fill(
                      child: ClipOval(
                        child: Image.asset(
                          'assets/images/asha_avatar_new.png',
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    // Live AI Indicator Dot (Emerald Green)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Colors.white,
                            width: 2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF10B981).withValues(alpha: 0.8),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
