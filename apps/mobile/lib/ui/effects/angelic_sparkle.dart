// angelic_sparkle.dart
// Ethereal angelic sparkle particle physics, celestial starlight glows,
// and smooth animated transitions for NeuroBridge Asha.

import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../../core/mobile_services.dart';

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
/// Asha slowly rises from the bottom with dynamic sound, liquid glass effects, smiles, waves, and talks.
class AngelicSparkleSplash extends StatefulWidget {
  const AngelicSparkleSplash({
    super.key,
    required this.onFinished,
    this.services,
  });

  final VoidCallback onFinished;
  final MobileServices? services;

  @override
  State<AngelicSparkleSplash> createState() => _AngelicSparkleSplashState();
}

class _AngelicSparkleSplashState extends State<AngelicSparkleSplash>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;
  late final Animation<double> _rise;
  late final Animation<double> _glow;
  late final Animation<double> _wave;
  late final Animation<double> _talk;
  late final Animation<double> _fade;
  bool _soundPlayed = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    final isTest = WidgetsBinding.instance.runtimeType.toString().contains('Test');
    _anim = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: isTest ? 100 : 4800),
    );

    _rise = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.0, 0.40, curve: Curves.easeOutCubic),
    );

    _glow = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.20, 0.85, curve: Curves.easeInOut),
    );

    _wave = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.35, 0.75, curve: Curves.easeInOut),
    );

    _talk = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.42, 0.85, curve: Curves.easeOutBack),
    );

    _fade = CurvedAnimation(
      parent: _anim,
      curve: const Interval(0.88, 1.0, curve: Curves.easeInOut),
    );

    _anim.addListener(() {
      if (_anim.value >= 0.35 && !_soundPlayed) {
        _soundPlayed = true;
        _triggerGreeting();
      }
    });

    _anim.forward().then((_) {
      _complete();
    });
  }

  void _triggerGreeting() {
    if (widget.services != null) {
      widget.services!.voice.playChimeSound().then((_) async {
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted && !_finished) {
          await widget.services!.voice.speakAsha(
            "Hello! I am Asha, your voice and companion. I'm right here with you.",
            force: true,
          );
        }
      });
    }
  }

  void _complete() {
    if (!_finished) {
      _finished = true;
      if (mounted) widget.onFinished();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);

    return AnimatedBuilder(
      animation: _anim,
      builder: (context, child) {
        final fadeOut = (1.0 - _fade.value).clamp(0.0, 1.0);
        final riseY = (1.0 - _rise.value) * (screenSize.height * 0.55);
        final waveAngle = math.sin(_wave.value * math.pi * 4) * 0.08;

        return Opacity(
          opacity: fadeOut,
          child: GestureDetector(
            onTap: _complete,
            behavior: HitTestBehavior.opaque,
            child: Scaffold(
              body: Stack(
                fit: StackFit.expand,
                children: [
                  // 1. Serene Celestial Dawn & Liquid Glass Gradient Background
                  Container(
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Color(0xFFE0F2FE), // Soft Sky Blue
                          Color(0xFFF0FDF4), // Gentle Morning Mint
                          Color(0xFFFAF5FF), // Soft Starlight Violet
                          Color(0xFFF8FAFC), // Pure Pearl
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                  ),

                  // 2. Dynamic Starlight Sparkle Field
                  const AngelicSparkleField(particleCount: 36, centerGlow: true),

                  // 3. Ambient Floating Liquid Glass Orbs
                  Positioned(
                    top: screenSize.height * 0.15,
                    left: 24,
                    child: Container(
                      width: 120,
                      height: 120,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFF2DD4BF).withValues(alpha: 0.25 * _glow.value),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: screenSize.height * 0.20,
                    right: 28,
                    child: Container(
                      width: 140,
                      height: 140,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xFFF59E0B).withValues(alpha: 0.20 * _glow.value),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),

                  // 4. Central Rising Asha Character & Liquid Glass Stage
                  Center(
                    child: Transform.translate(
                      offset: Offset(0, riseY),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Concentric Pulse Rings when Talking
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                if (_talk.value > 0.05) ...[
                                  Container(
                                    width: 180 + 30 * _talk.value,
                                    height: 180 + 30 * _talk.value,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0xFF0D9488)
                                            .withValues(alpha: (0.35 * (1.0 - _talk.value)).clamp(0.0, 1.0)),
                                        width: 2.5,
                                      ),
                                    ),
                                  ),
                                  Container(
                                    width: 205 + 40 * _talk.value,
                                    height: 205 + 40 * _talk.value,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: const Color(0xFF38BDF8)
                                            .withValues(alpha: (0.25 * (1.0 - _talk.value)).clamp(0.0, 1.0)),
                                        width: 1.5,
                                      ),
                                    ),
                                  ),
                                ],

                                // Glowing Liquid Glass Aura Container
                                Transform.rotate(
                                  angle: waveAngle,
                                  child: Container(
                                    width: 156,
                                    height: 156,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: const LinearGradient(
                                        colors: [
                                          Color(0xFF0D9488),
                                          Color(0xFF38BDF8),
                                          Color(0xFFF59E0B),
                                        ],
                                        begin: Alignment.topLeft,
                                        end: Alignment.bottomRight,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF0D9488)
                                              .withValues(alpha: 0.38 * _glow.value),
                                          blurRadius: 40 + 20 * _glow.value,
                                          spreadRadius: 8 + 6 * _glow.value,
                                        ),
                                        BoxShadow(
                                          color: const Color(0xFFF59E0B)
                                              .withValues(alpha: 0.28 * _glow.value),
                                          blurRadius: 52,
                                          spreadRadius: 4,
                                        ),
                                      ],
                                    ),
                                    padding: const EdgeInsets.all(4.5),
                                    child: ClipOval(
                                      child: BackdropFilter(
                                        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                                        child: Container(
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: Colors.white.withValues(alpha: 0.9),
                                          ),
                                          child: Stack(
                                            fit: StackFit.expand,
                                            children: [
                                              // Base smiling new avatar
                                              Image.asset(
                                                'assets/images/asha_avatar_new.png',
                                                fit: BoxFit.cover,
                                              ),
                                              // Smooth cross-fade to waving pose
                                              Opacity(
                                                opacity: (_wave.value * 2.2).clamp(0.0, 1.0),
                                                child: Image.asset(
                                                  'assets/images/asha_waving.png',
                                                  fit: BoxFit.cover,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 22),

                            // Liquid Glass Speech Bubble when Talking
                            if (_talk.value > 0.05) ...[
                              Transform.scale(
                                scale: (0.75 + 0.25 * _talk.value).clamp(0.0, 1.0),
                                child: Opacity(
                                  opacity: _talk.value.clamp(0.0, 1.0),
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(22),
                                    child: BackdropFilter(
                                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 18, vertical: 12),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(alpha: 0.88),
                                          borderRadius: BorderRadius.circular(22),
                                          border: Border.all(
                                            color: Colors.white.withValues(alpha: 0.95),
                                            width: 1.8,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFF0D9488)
                                                  .withValues(alpha: 0.18),
                                              blurRadius: 22,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              padding: const EdgeInsets.all(6),
                                              decoration: const BoxDecoration(
                                                color: Color(0xFFD1FAE5),
                                                shape: BoxShape.circle,
                                              ),
                                              child: const Icon(
                                                Icons.record_voice_over_rounded,
                                                color: Color(0xFF059669),
                                                size: 18,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            const Flexible(
                                              child: Text(
                                                "“Hello! I am Asha. I'm right here with you.”",
                                                style: TextStyle(
                                                  fontSize: 13.5,
                                                  fontWeight: FontWeight.w800,
                                                  color: Color(0xFF0F172A),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 18),
                            ],

                            // App Name with Radiant Gradient Shader
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
                                  fontSize: 25,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 2.8,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),

                            // Reassuring Subtitle
                            Text(
                              'Every Voice Reimagined · Assistive AAC & Companion',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12.5,
                                letterSpacing: 0.3,
                                color: const Color(0xFF334155)
                                    .withValues(alpha: _glow.value.clamp(0.4, 1.0)),
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 28),

                            // Liquid Glass "Get Started" / Continue Pill
                            ClipRRect(
                              borderRadius: BorderRadius.circular(30),
                              child: BackdropFilter(
                                filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 22, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.75),
                                    borderRadius: BorderRadius.circular(30),
                                    border: Border.all(
                                      color: const Color(0xFF0D9488).withValues(alpha: 0.4),
                                      width: 1.4,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF0D9488)
                                            .withValues(alpha: 0.15),
                                        blurRadius: 16,
                                      ),
                                    ],
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        'Get Started',
                                        style: TextStyle(
                                          color: Color(0xFF0D9488),
                                          fontWeight: FontWeight.w800,
                                          fontSize: 13,
                                        ),
                                      ),
                                      SizedBox(width: 6),
                                      Icon(
                                        Icons.arrow_forward_rounded,
                                        size: 16,
                                        color: Color(0xFF0D9488),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
                  'assets/images/asha_avatar_new.png',
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
