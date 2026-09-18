import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

/// Global theme controller to manage Dark vs Bright mode across the UI.
class LiquidGlassThemeController {
  LiquidGlassThemeController._();
  static final ValueNotifier<bool> isDarkNotifier = ValueNotifier<bool>(true);

  static bool get isDark => isDarkNotifier.value;
  static set isDark(bool value) => isDarkNotifier.value = value;
  static void toggle() => isDarkNotifier.value = !isDarkNotifier.value;
}

/// Dynamic theme styling properties for Liquid Glass UI.
class LiquidGlassThemeData {
  const LiquidGlassThemeData({
    required this.isDark,
    required this.bgGradient,
    required this.cardGlass,
    required this.cardBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.pillGlass,
    required this.pillBorder,
    required this.glowShadow,
    required this.waterColor,
    required this.foodColor,
    required this.toiletColor,
    required this.restColor,
    required this.familyColor,
    required this.entertainmentColor,
    required this.sosColor,
    required this.speakColor,
  });

  final bool isDark;
  final Gradient bgGradient;
  final Color cardGlass;
  final Color cardBorder;
  final Color textPrimary;
  final Color textSecondary;
  final Color pillGlass;
  final Color pillBorder;
  final Color glowShadow;

  final Color waterColor;
  final Color foodColor;
  final Color toiletColor;
  final Color restColor;
  final Color familyColor;
  final Color entertainmentColor;
  final Color sosColor;
  final Color speakColor;

  static const dark = LiquidGlassThemeData(
    isDark: true,
    bgGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFF070A12), Color(0xFF0D1527), Color(0xFF0A101D)],
    ),
    cardGlass: Color(0x281E293B),
    cardBorder: Color(0x3838BDF8),
    textPrimary: Color(0xFFF8FAFC),
    textSecondary: Color(0xFF94A3B8),
    pillGlass: Color(0x401E293B),
    pillBorder: Color(0x4038BDF8),
    glowShadow: Color(0x2238BDF8),
    waterColor: Color(0xFF38BDF8),
    foodColor: Color(0xFFFBBF24),
    toiletColor: Color(0xFFA855F7),
    restColor: Color(0xFF34D399),
    familyColor: Color(0xFFFB7185),
    entertainmentColor: Color(0xFF818CF8),
    sosColor: Color(0xFFF43F5E),
    speakColor: Color(0xFF22D3EE),
  );

  static const bright = LiquidGlassThemeData(
    isDark: false,
    bgGradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [Color(0xFFF8FAFC), Color(0xFFEEF2F6), Color(0xFFE2E8F0)],
    ),
    cardGlass: Color(0xDCFFFFFF),
    cardBorder: Color(0x6094A3B8),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF475569),
    pillGlass: Color(0xEEFFFFFF),
    pillBorder: Color(0x80CBD5E1),
    glowShadow: Color(0x12000000),
    waterColor: Color(0xFF0284C7),
    foodColor: Color(0xFFD97706),
    toiletColor: Color(0xFF7C3AED),
    restColor: Color(0xFF059669),
    familyColor: Color(0xFFE11D48),
    entertainmentColor: Color(0xFF4F46E5),
    sosColor: Color(0xFFDC2626),
    speakColor: Color(0xFF0891B2),
  );

  static LiquidGlassThemeData current(BuildContext context) {
    // If context provides brightness or if our controller is listened to
    return LiquidGlassThemeController.isDark ? dark : bright;
  }
}

/// A liquid glass card component featuring blur filter, specular border, and ambient glow.
class LiquidGlassCard extends StatefulWidget {
  const LiquidGlassCard({
    required this.child,
    this.borderRadius = 22.0,
    this.blur = 18.0,
    this.padding,
    this.margin,
    this.customGlowColor,
    this.customSurfaceColor,
    this.customBorderColor,
    this.borderWidth = 1.2,
    this.onTap,
    this.onLongPress,
    super.key,
  });

  final Widget child;
  final double borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? customGlowColor;
  final Color? customSurfaceColor;
  final Color? customBorderColor;
  final double borderWidth;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  State<LiquidGlassCard> createState() => _LiquidGlassCardState();
}

class _LiquidGlassCardState extends State<LiquidGlassCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = LiquidGlassThemeData.current(context);
    final glowColor = widget.customGlowColor ?? theme.glowShadow;
    final surfaceColor = widget.customSurfaceColor ?? theme.cardGlass;
    final borderColor = widget.customBorderColor ?? theme.cardBorder;

    Widget content = Container(
      padding: widget.padding ?? const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: surfaceColor,
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: borderColor,
          width: widget.borderWidth,
        ),
      ),
      child: widget.child,
    );

    content = ClipRRect(
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(
          sigmaX: widget.blur,
          sigmaY: widget.blur,
        ),
        child: content,
      ),
    );

    if (widget.margin != null) {
      content = Padding(
        padding: widget.margin!,
        child: content,
      );
    }

    final isInteractive = widget.onTap != null || widget.onLongPress != null;

    if (!isInteractive) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          boxShadow: [
            BoxShadow(
              color: glowColor,
              blurRadius: 20,
              spreadRadius: 1,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: content,
      );
    }

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? 0.97 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            boxShadow: [
              BoxShadow(
                color: glowColor.withValues(alpha: _pressed ? 0.45 : 0.25),
                blurRadius: _pressed ? 28 : 18,
                spreadRadius: _pressed ? 2 : 0,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: content,
        ),
      ),
    );
  }
}

/// Compact liquid glass pill badge with icon, label and optional metric.
class LiquidGlassPill extends StatelessWidget {
  const LiquidGlassPill({
    required this.icon,
    required this.label,
    this.value,
    this.accentColor,
    this.onTap,
    this.isActive = false,
    super.key,
  });

  final IconData icon;
  final String label;
  final String? value;
  final Color? accentColor;
  final VoidCallback? onTap;
  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final theme = LiquidGlassThemeData.current(context);
    final color = accentColor ?? (theme.isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7));

    Widget pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? color.withValues(alpha: theme.isDark ? 0.35 : 0.2)
            : theme.pillGlass,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: isActive ? color : theme.pillBorder,
          width: isActive ? 1.6 : 1.0,
        ),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.3),
                  blurRadius: 12,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: theme.textPrimary,
              letterSpacing: 0.2,
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                value!,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    pill = ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: pill,
      ),
    );

    if (onTap == null) return pill;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: pill,
    );
  }
}

/// Hero Action Button with glowing liquid glass gradient and tactile animation.
class LiquidGlassHeroButton extends StatefulWidget {
  const LiquidGlassHeroButton({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accentColor,
    required this.onTap,
    this.height = 84,
    this.onLongPress,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accentColor;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final double height;

  @override
  State<LiquidGlassHeroButton> createState() => _LiquidGlassHeroButtonState();
}

class _LiquidGlassHeroButtonState extends State<LiquidGlassHeroButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = LiquidGlassThemeData.current(context);

    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) => setState(() => _pressed = false),
      onTapCancel: () => setState(() => _pressed = false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _pressed ? 0.96 : 1.0,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          constraints: BoxConstraints(minHeight: widget.height),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: widget.accentColor.withValues(alpha: _pressed ? 0.5 : 0.3),
                blurRadius: _pressed ? 24 : 16,
                spreadRadius: 1,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                constraints: BoxConstraints(minHeight: widget.height),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      widget.accentColor.withValues(alpha: theme.isDark ? 0.28 : 0.18),
                      widget.accentColor.withValues(alpha: theme.isDark ? 0.12 : 0.06),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: widget.accentColor.withValues(alpha: 0.5),
                    width: 1.5,
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: widget.accentColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: widget.accentColor.withValues(alpha: 0.4),
                          width: 1.2,
                        ),
                      ),
                      child: Icon(
                        widget.icon,
                        color: widget.accentColor,
                        size: 24,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w800,
                              color: theme.textPrimary,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.subtitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.textSecondary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.arrow_forward_ios_rounded,
                      color: widget.accentColor.withValues(alpha: 0.7),
                      size: 14,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One-tap Theme Toggle Pill (☀️ Bright / 🌙 Dark)
class ThemeToggleSwitch extends StatelessWidget {
  const ThemeToggleSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: LiquidGlassThemeController.isDarkNotifier,
      builder: (context, isDark, _) {
        final theme = LiquidGlassThemeData.current(context);
        return InkWell(
          onTap: LiquidGlassThemeController.toggle,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: theme.pillGlass,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: theme.pillBorder, width: 1.2),
              boxShadow: [
                BoxShadow(
                  color: theme.glowShadow,
                  blurRadius: 10,
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                  size: 16,
                  color: isDark ? const Color(0xFFFBBF24) : const Color(0xFFF59E0B),
                ),
                const SizedBox(width: 6),
                Text(
                  isDark ? 'Dark' : 'Bright',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: theme.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Animated Canvas Audio Waveform Visualizer for live voice preview and audio stream.
class AudioWaveformVisualizer extends StatefulWidget {
  const AudioWaveformVisualizer({
    this.isActive = false,
    this.color = const Color(0xFF38BDF8),
    this.barCount = 18,
    this.height = 36,
    super.key,
  });

  final bool isActive;
  final Color color;
  final int barCount;
  final double height;

  @override
  State<AudioWaveformVisualizer> createState() => _AudioWaveformVisualizerState();
}

class _AudioWaveformVisualizerState extends State<AudioWaveformVisualizer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return SizedBox(
          height: widget.height,
          child: CustomPaint(
            size: Size(double.infinity, widget.height),
            painter: _WaveformPainter(
              progress: _controller.value,
              isActive: widget.isActive,
              color: widget.color,
              barCount: widget.barCount,
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.progress,
    required this.isActive,
    required this.color,
    required this.barCount,
  });

  final double progress;
  final bool isActive;
  final Color color;
  final int barCount;

  @override
  void paint(Canvas canvas, Size size) {
    final barWidth = (size.width / (barCount * 1.6)).clamp(3.0, 7.0);
    final gap = (size.width - (barCount * barWidth)) / (barCount - 1);
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = barWidth;

    for (int i = 0; i < barCount; i++) {
      final x = i * (barWidth + gap) + (barWidth / 2);
      final phase = (i / barCount) * 2 * math.pi;
      final wave = math.sin((progress * 2 * math.pi) + phase).abs();

      final double heightRatio;
      if (isActive) {
        heightRatio = 0.2 + (0.75 * wave);
      } else {
        heightRatio = 0.15 + (0.1 * math.sin(phase).abs());
      }

      final barHeight = size.height * heightRatio;
      final yTop = (size.height - barHeight) / 2;
      final yBottom = yTop + barHeight;

      paint.color = color.withValues(alpha: isActive ? (0.4 + 0.6 * wave) : 0.3);
      canvas.drawLine(Offset(x, yTop), Offset(x, yBottom), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WaveformPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.isActive != isActive ||
        oldDelegate.color != color;
  }
}
