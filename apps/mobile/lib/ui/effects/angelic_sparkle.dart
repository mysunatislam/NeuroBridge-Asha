// angelic_sparkle.dart
// Ethereal angelic sparkle particle physics, celestial starlight glows,
// and smooth animated transitions for NeuroBridge Asha.

import 'dart:math' as math;
import 'package:flutter/material.dart';

/// A single radiant stardust particle.
class SparkleParticle {
  SparkleParticle({
    required this.x,
    required this.y,
    required this.size,
    required this.maxOpacity,
    required this.color,
    required this.speedX,
    required this.speedY,
    required this.phase,
    required this.isStar,
    required this.rotationSpeed,
  });

  double x;
  double y;
  double size;
  double maxOpacity;
  Color color;
  double speedX;
  double speedY;
  double phase;
  bool isStar;
  double rotationSpeed;

  factory SparkleParticle.random(Size area, math.Random rng) {
    final colors = [
      const Color(0xFF4FD1C5), // Ethereal Teal
      const Color(0xFFFFD166), // Golden Starlight
      const Color(0xFFF2A65A), // Warm Radiant Amber
      const Color(0xFFE0F7FA), // Soft Celestial White
      const Color(0xFFFFF8E1), // Angelic Cream
    ];

    return SparkleParticle(
      x: rng.nextDouble() * area.width,
      y: rng.nextDouble() * area.height,
      size: 3.0 + rng.nextDouble() * 9.0,
      maxOpacity: 0.4 + rng.nextDouble() * 0.55,
      color: colors[rng.nextInt(colors.length)],
      speedX: (rng.nextDouble() - 0.5) * 0.4,
      speedY: -0.25 - rng.nextDouble() * 0.65, // Gentle upward drift
      phase: rng.nextDouble() * math.pi * 2,
      isStar: rng.nextDouble() > 0.4,
      rotationSpeed: (rng.nextDouble() - 0.5) * 1.5,
    );
  }

  void update(Size area, double delta) {
    x += speedX;
    y += speedY;
    phase += delta * 2.5;

    // Wrap around screen bounds
    if (y < -20) {
      y = area.height + 10;
      x = math.Random().nextDouble() * area.width;
    }
    if (x < -20) x = area.width + 10;
    if (x > area.width + 20) x = -10;
  }
}

/// CustomPainter that renders radiant starbursts, diamond sparkles, and soft halos.
class AngelicSparklePainter extends CustomPainter {
  AngelicSparklePainter({
    required this.particles,
    required this.progress,
    this.centerGlow = true,
  });

  final List<SparkleParticle> particles;
  final double progress;
  final bool centerGlow;

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Radiant central ambient halo glow if requested
    if (centerGlow) {
      final center = Offset(size.width / 2, size.height / 2);
      final radius = math.min(size.width, size.height) * 0.65;
      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0x334FD1C5),
            const Color(0x18FFD166),
            const Color(0x08161F29),
            Colors.transparent,
          ],
          stops: const [0.0, 0.4, 0.75, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: radius));

      canvas.drawCircle(center, radius, glowPaint);
    }

    // 2. Render each floating sparkle particle
    for (final p in particles) {
      final currentOpacity = (p.maxOpacity * (0.5 + 0.5 * math.sin(p.phase))).clamp(0.0, 1.0);
      final paint = Paint()
        ..color = p.color.withValues(alpha: currentOpacity)
        ..style = PaintingStyle.fill;

      final center = Offset(p.x, p.y);

      if (p.isStar) {
        // Draw 4-pointed radiant starlight diamond
        final path = Path();
        final s = p.size;
        final rot = p.phase * p.rotationSpeed;
        final cosR = math.cos(rot);
        final sinR = math.sin(rot);

        Offset rotate(double dx, double dy) {
          return Offset(
            center.dx + dx * cosR - dy * sinR,
            center.dy + dx * sinR + dy * cosR,
          );
        }

        // Diamond points: North, East, South, West with tapered core
        path.moveTo(rotate(0, -s).dx, rotate(0, -s).dy);
        path.quadraticBezierTo(
          rotate(0, -s * 0.2).dx, rotate(0, -s * 0.2).dy,
          rotate(s * 0.25, 0).dx, rotate(s * 0.25, 0).dy,
        );
        path.quadraticBezierTo(
          rotate(s * 0.2, 0).dx, rotate(s * 0.2, 0).dy,
          rotate(0, s).dx, rotate(0, s).dy,
        );
        path.quadraticBezierTo(
          rotate(0, s * 0.2).dx, rotate(0, s * 0.2).dy,
          rotate(-s * 0.25, 0).dx, rotate(-s * 0.25, 0).dy,
        );
        path.quadraticBezierTo(
          rotate(-s * 0.2, 0).dx, rotate(-s * 0.2, 0).dy,
          rotate(0, -s).dx, rotate(0, -s).dy,
        );
        path.close();

        canvas.drawPath(path, paint);

        // Soft center glow pinpoint
        final centerGlowPaint = Paint()
          ..color = Colors.white.withValues(alpha: currentOpacity * 0.9)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(center, p.size * 0.18, centerGlowPaint);
      } else {
        // Soft glowing orb with ambient halo
        final haloPaint = Paint()
          ..color = p.color.withValues(alpha: currentOpacity * 0.45)
          ..style = PaintingStyle.fill;
        canvas.drawCircle(center, p.size * 1.5, haloPaint);
        canvas.drawCircle(center, p.size * 0.75, paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant AngelicSparklePainter oldDelegate) => true;
}

/// A full-screen or boxed dynamic sparkle backdrop with smooth animation.
class AngelicSparkleField extends StatefulWidget {
  const AngelicSparkleField({
    super.key,
    this.particleCount = 28,
    this.child,
    this.centerGlow = true,
  });

  final int particleCount;
  final Widget? child;
  final bool centerGlow;

  @override
  State<AngelicSparkleField> createState() => _AngelicSparkleFieldState();
}

class _AngelicSparkleFieldState extends State<AngelicSparkleField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final List<SparkleParticle> _particles = [];
  final math.Random _rng = math.Random();
  Size _lastSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..addListener(_onTick)..repeat();
  }

  void _onTick() {
    if (_lastSize == Size.zero) return;
    for (final p in _particles) {
      p.update(_lastSize, 0.016);
    }
    setState(() {});
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        if (_particles.isEmpty || _lastSize != size) {
          _lastSize = size;
          _particles.clear();
          for (var i = 0; i < widget.particleCount; i++) {
            _particles.add(SparkleParticle.random(size, _rng));
          }
        }

        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              size: size,
              painter: AngelicSparklePainter(
                particles: _particles,
                progress: _controller.value,
                centerGlow: widget.centerGlow,
              ),
            ),
            if (widget.child != null) widget.child!,
          ],
        );
      },
    );
  }
}

/// Ethereal Angelic Sparkle App Launch Splash Screen.
/// Plays on app opening with breathing halo, starlight burst, and smooth transition.
class AngelicSparkleSplash extends StatefulWidget {
  const AngelicSparkleSplash({super.key, required this.onFinished});

  final VoidCallback onFinished;

  @override
  State<AngelicSparkleSplash> createState() => _AngelicSparkleSplashState();
}

class _AngelicSparkleSplashState extends State<AngelicSparkleSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _scale;
  late final Animation<double> _glow;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );

    _scale = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.0, 0.65, curve: Curves.easeOutBack),
    );

    _glow = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.2, 0.85, curve: Curves.easeInOut),
    );

    _fade = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.75, 1.0, curve: Curves.easeInOut),
    );

    _anim.forward().then((_) {
      if (mounted) widget.onFinished();
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final fadeOut = (1.0 - _fade.value).clamp(0.0, 1.0);

        return Opacity(
          opacity: fadeOut,
          child: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                // 1. Serene Celestial Dawn Background
                Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Color(0xFFF0FDF4), // Soft Morning Mint
                        Color(0xFFF8FAFC), // Pure Serene Pearl
                        Color(0xFFEFF6FF), // Soft Starlight Blue
                      ],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),

                // 2. Dynamic Starlight Sparkle Field
                const AngelicSparkleField(particleCount: 32, centerGlow: true),

                // 3. Central Angelic Avatar & Branding
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Glowing Aura Container
                      Transform.scale(
                        scale: 0.85 + 0.25 * _scale.value,
                        child: Container(
                          width: 130,
                          height: 130,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: const LinearGradient(
                              colors: [Color(0xFF0D9488), Color(0xFFF59E0B)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(0xFF0D9488).withValues(alpha: 0.35 * _glow.value),
                                blurRadius: 36 + 18 * _glow.value,
                                spreadRadius: 6 + 8 * _glow.value,
                              ),
                              BoxShadow(
                                color: const Color(0xFFF59E0B).withValues(alpha: 0.25 * _glow.value),
                                blurRadius: 48,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          padding: const EdgeInsets.all(3.5),
                          child: Container(
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.asset(
                              'assets/images/asha-avatar.webp',
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),

                      // App Name with Radiant Gradient
                      ShaderMask(
                        shaderCallback: (bounds) => const LinearGradient(
                          colors: [
                            Color(0xFF0F172A),
                            Color(0xFF0D9488),
                            Color(0xFFD97706),
                          ],
                          stops: [0.0, 0.65, 1.0],
                        ).createShader(bounds),
                        child: const Text(
                          'NEUROBRIDGE ASHA',
                          style: TextStyle(
                            fontFamily: 'Space Grotesk',
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 2.5,
                            color: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),

                      // Reassuring Subtitle
                      Text(
                        'Every Voice Reimagined · Assistive AAC & Companion',
                        style: TextStyle(
                          fontSize: 12.5,
                          letterSpacing: 0.3,
                          color: const Color(0xFF475569).withValues(alpha: _glow.value),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 36),

                      // Subtle Shimmering Indicator
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation(
                            const Color(0xFF0D9488).withValues(alpha: 0.8),
                          ),
                        ),
                      ),
                    ],
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

/// Floating Angelic Asha Avatar button with breathing halo & starlight pulse.
class AngelicAshaButton extends StatefulWidget {
  const AngelicAshaButton({
    super.key,
    required this.onTap,
    this.isCaregiver = false,
  });

  final VoidCallback onTap;
  final bool isCaregiver;

  @override
  State<AngelicAshaButton> createState() => _AngelicAshaButtonState();
}

class _AngelicAshaButtonState extends State<AngelicAshaButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseColor = widget.isCaregiver ? const Color(0xFFC04B67) : const Color(0xFF0B756A);
    final glowColor = widget.isCaregiver ? const Color(0xFFE992A4) : const Color(0xFF4FD1C5);

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final val = _pulse.value;
        return Semantics(
          button: true,
          label: 'Open Asha companion',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: widget.onTap,
            child: Container(
              width: 74,
              height: 74,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [glowColor, baseColor],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: glowColor.withValues(alpha: 0.35 + 0.30 * val),
                    blurRadius: 16 + 10 * val,
                    spreadRadius: 2 + 3 * val,
                  ),
                ],
              ),
              padding: const EdgeInsets.all(3.0),
              child: Container(
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                ),
                clipBehavior: Clip.antiAlias,
                child: Image.asset(
                  'assets/images/asha-avatar.webp',
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
