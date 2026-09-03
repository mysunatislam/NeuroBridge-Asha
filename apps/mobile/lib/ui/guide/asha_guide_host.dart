import 'dart:async';
import 'dart:collection';

import 'package:fingerspeak_mobile/services/asha_guide_service.dart';
import 'package:flutter/material.dart';

typedef AshaGuideNarrator = FutureOr<void> Function(String message);
typedef AshaGuideStepRevealer = FutureOr<void> Function(AshaGuideStep step);

/// Tracks one or more possible widgets for every guide step.
///
/// Multiple targets are supported so the host can choose the mounted, visible
/// variant when patient access modes expose different session controls.
class AshaGuideTargetRegistry extends ChangeNotifier {
  final Map<AshaGuideStep, LinkedHashSet<GlobalKey>> _targets = {};
  bool _notificationScheduled = false;
  bool _disposed = false;

  void register(AshaGuideStep step, GlobalKey key) {
    final keys = _targets.putIfAbsent(step, LinkedHashSet.new);
    if (keys.add(key)) _notifyAfterFrame();
  }

  void unregister(AshaGuideStep step, GlobalKey key) {
    final keys = _targets[step];
    if (keys == null || !keys.remove(key)) return;
    if (keys.isEmpty) _targets.remove(step);
    _notifyAfterFrame();
  }

  /// Re-measures targets after a route, tab, or scroll position changes.
  void refresh() => _notifyAfterFrame();

  void _notifyAfterFrame() {
    if (_notificationScheduled || _disposed) return;
    _notificationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notificationScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  Rect? rectFor(AshaGuideStep step, RenderBox ancestor) {
    final keys = _targets[step];
    if (keys == null) return null;
    for (final key in keys) {
      final context = key.currentContext;
      if (context == null || _isOffstage(context)) continue;
      final renderObject = context.findRenderObject();
      if (renderObject is! RenderBox ||
          !renderObject.attached ||
          !renderObject.hasSize ||
          renderObject.size.isEmpty) {
        continue;
      }
      final topLeft = renderObject.localToGlobal(
        Offset.zero,
        ancestor: ancestor,
      );
      return topLeft & renderObject.size;
    }
    return null;
  }

  bool _isOffstage(BuildContext context) {
    var hidden = false;
    context.visitAncestorElements((element) {
      final widget = element.widget;
      if (widget is Offstage && widget.offstage) {
        hidden = true;
        return false;
      }
      if (widget is Visibility && !widget.visible) {
        hidden = true;
        return false;
      }
      return true;
    });
    return hidden;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class _AshaGuideScope extends InheritedWidget {
  const _AshaGuideScope({
    required this.registry,
    required super.child,
  });

  final AshaGuideTargetRegistry registry;

  static AshaGuideTargetRegistry? maybeRegistryOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_AshaGuideScope>()?.registry;

  @override
  bool updateShouldNotify(_AshaGuideScope oldWidget) =>
      registry != oldWidget.registry;
}

/// Wraps a real app control that Asha Guide should highlight.
class AshaGuideTarget extends StatefulWidget {
  const AshaGuideTarget({
    required this.step,
    required this.child,
    super.key,
  });

  final AshaGuideStep step;
  final Widget child;

  @override
  State<AshaGuideTarget> createState() => _AshaGuideTargetState();
}

class _AshaGuideTargetState extends State<AshaGuideTarget> {
  final GlobalKey _targetKey = GlobalKey();
  AshaGuideTargetRegistry? _registry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _attachTo(_AshaGuideScope.maybeRegistryOf(context));
  }

  @override
  void didUpdateWidget(AshaGuideTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.step == widget.step) return;
    _registry?.unregister(oldWidget.step, _targetKey);
    _registry?.register(widget.step, _targetKey);
    _refreshAfterLayout();
  }

  void _attachTo(AshaGuideTargetRegistry? next) {
    if (identical(next, _registry)) return;
    _registry?.unregister(widget.step, _targetKey);
    _registry = next;
    next?.register(widget.step, _targetKey);
    _refreshAfterLayout();
  }

  void _refreshAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _registry?.refresh();
    });
  }

  @override
  void dispose() {
    _registry?.unregister(widget.step, _targetKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(
        key: _targetKey,
        child: widget.child,
      );
}

/// Places the visual Asha Guide over the application without creating a modal
/// barrier. The spotlight and pointer ignore input; only the compact guide card
/// accepts taps, leaving safety controls elsewhere on screen operable.
class AshaGuideHost extends StatefulWidget {
  const AshaGuideHost({
    required this.service,
    required this.child,
    this.registry,
    this.onNarrate,
    this.onRevealStep,
    super.key,
  });

  final AshaGuideService service;
  final Widget child;
  final AshaGuideTargetRegistry? registry;
  final AshaGuideNarrator? onNarrate;
  final AshaGuideStepRevealer? onRevealStep;

  @override
  State<AshaGuideHost> createState() => _AshaGuideHostState();
}

class _AshaGuideHostState extends State<AshaGuideHost> {
  late AshaGuideTargetRegistry _registry;
  AshaGuideStep? _enteredStep;

  @override
  void initState() {
    super.initState();
    _registry = widget.registry ?? AshaGuideTargetRegistry();
    widget.service.addListener(_handleGuideChanged);
    _registry.addListener(_handleRegistryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterCurrentStep());
  }

  @override
  void didUpdateWidget(AshaGuideHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      oldWidget.service.removeListener(_handleGuideChanged);
      widget.service.addListener(_handleGuideChanged);
      _enteredStep = null;
    }
    if (!identical(oldWidget.registry, widget.registry)) {
      _registry.removeListener(_handleRegistryChanged);
      if (oldWidget.registry == null) _registry.dispose();
      _registry = widget.registry ?? AshaGuideTargetRegistry();
      _registry.addListener(_handleRegistryChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterCurrentStep());
  }

  @override
  void dispose() {
    widget.service.removeListener(_handleGuideChanged);
    _registry.removeListener(_handleRegistryChanged);
    if (widget.registry == null) _registry.dispose();
    super.dispose();
  }

  void _handleGuideChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _enterCurrentStep());
  }

  void _handleRegistryChanged() {
    if (mounted) setState(() {});
  }

  void _enterCurrentStep() {
    if (!mounted || !widget.service.isActive) return;
    final step = widget.service.step;
    if (_enteredStep == step) return;
    _enteredStep = step;
    final reveal = widget.onRevealStep;
    if (reveal != null) unawaited(Future.sync(() => reveal(step)));
    _narrate();
  }

  void _narrate() {
    final narrator = widget.onNarrate;
    if (narrator == null || !widget.service.isActive) return;
    unawaited(Future.sync(() => narrator(widget.service.step.message)));
  }

  bool _onScroll(ScrollNotification notification) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _registry.refresh();
    });
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return _AshaGuideScope(
      registry: _registry,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              fit: StackFit.expand,
              children: [
                widget.child,
                if (widget.service.isActive)
                  _buildGuideOverlay(context, constraints.biggest),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildGuideOverlay(BuildContext context, Size size) {
    final hostRenderObject = context.findRenderObject();
    final targetRect = hostRenderObject is RenderBox
        ? _registry.rectFor(widget.service.step, hostRenderObject)
        : null;
    final reduceMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final pointer = _pointerPosition(size, targetRect);

    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              key: const ValueKey('asha-guide-spotlight'),
              painter: _AshaSpotlightPainter(targetRect: targetRect),
            ),
          ),
        ),
        AnimatedPositioned(
          key: const ValueKey('asha-guide-pointer-position'),
          duration:
              reduceMotion ? Duration.zero : const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          left: pointer.dx,
          top: pointer.dy,
          child: const IgnorePointer(child: _AshaPointer()),
        ),
        _GuideCard(
          service: widget.service,
          targetRect: targetRect,
          targetMissing:
              widget.service.step.expectsTarget && targetRect == null,
          onReplay: _narrate,
        ),
      ],
    );
  }

  Offset _pointerPosition(Size size, Rect? targetRect) {
    const pointerSize = 58.0;
    final desired = targetRect == null
        ? Offset(size.width - pointerSize - 20, 28)
        : Offset(targetRect.right - 18, targetRect.top - pointerSize - 8);
    final maxX =
        size.width > pointerSize + 16 ? size.width - pointerSize - 8 : 8.0;
    final maxY =
        size.height > pointerSize + 16 ? size.height - pointerSize - 8 : 8.0;
    return Offset(
      desired.dx.clamp(8.0, maxX),
      desired.dy.clamp(8.0, maxY),
    );
  }
}

class _GuideCard extends StatelessWidget {
  const _GuideCard({
    required this.service,
    required this.targetRect,
    required this.targetMissing,
    required this.onReplay,
  });

  final AshaGuideService service;
  final Rect? targetRect;
  final bool targetMissing;
  final VoidCallback onReplay;

  @override
  Widget build(BuildContext context) {
    final placeAtTop = targetRect != null &&
        targetRect!.center.dy > MediaQuery.sizeOf(context).height / 2;
    final card = SafeArea(
      minimum: const EdgeInsets.all(12),
      child: Align(
        alignment: placeAtTop ? Alignment.topCenter : Alignment.bottomCenter,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 520,
            maxHeight: MediaQuery.sizeOf(context).height * 0.72,
          ),
          child: Semantics(
            container: true,
            liveRegion: true,
            label:
                'Asha Guide. Step ${service.visibleStepNumber} of ${service.visibleStepCount}. ${service.step.title}. ${service.step.message}',
            child: Material(
              key: const ValueKey('asha-guide-card'),
              elevation: 16,
              color: const Color(0xFFFFFBEB),
              shadowColor: const Color(0x660F766E),
              borderRadius: BorderRadius.circular(22),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 14, 14, 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(
                    color: const Color(0xFF5EEAD4),
                    width: 1.5,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const CircleAvatar(
                          radius: 18,
                          backgroundColor: Color(0xFFCCFBF1),
                          child: Icon(
                            Icons.volunteer_activism,
                            color: Color(0xFF0F766E),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Asha Guide',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleMedium
                                    ?.copyWith(
                                      color: const Color(0xFF134E4A),
                                      fontWeight: FontWeight.w800,
                                    ),
                              ),
                              Text(
                                'Step ${service.visibleStepNumber} of ${service.visibleStepCount}',
                                style: const TextStyle(
                                  color: Color(0xFF64748B),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Replay Asha voice',
                          onPressed: onReplay,
                          icon: const Icon(
                            Icons.volume_up_outlined,
                            color: Color(0xFF0F766E),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Flexible(
                      child: SingleChildScrollView(
                        key: const ValueKey('asha-guide-copy-scroll'),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              service.step.title,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
                                    color: const Color(0xFF134E4A),
                                    fontWeight: FontWeight.w800,
                                  ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              service.step.message,
                              style: const TextStyle(
                                color: Color(0xFF334155),
                                fontSize: 15,
                                height: 1.35,
                              ),
                            ),
                            if (targetMissing) ...[
                              const SizedBox(height: 8),
                              const Text(
                                'The highlighted control is not visible yet. Open the requested screen, or continue when you are ready.',
                                key: ValueKey('asha-guide-missing-target'),
                                style: TextStyle(
                                  color: Color(0xFF92400E),
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      alignment: WrapAlignment.end,
                      children: [
                        TextButton(
                          onPressed: service.skip,
                          child: const Text('Skip guide'),
                        ),
                        OutlinedButton.icon(
                          onPressed: service.step == AshaGuideStep.welcome
                              ? null
                              : service.back,
                          icon: const Icon(Icons.arrow_back, size: 18),
                          label: const Text('Back'),
                        ),
                        FilledButton.icon(
                          onPressed: service.next,
                          icon: Icon(
                            service.step == AshaGuideStep.report
                                ? Icons.check
                                : Icons.arrow_forward,
                            size: 18,
                          ),
                          label: Text(
                            service.step == AshaGuideStep.report
                                ? 'Finish'
                                : 'Next',
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Positioned.fill(child: card);
  }
}

class _AshaPointer extends StatelessWidget {
  const _AshaPointer();

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Asha Guide pointer',
      image: true,
      child: Container(
        key: const ValueKey('asha-guide-pointer'),
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFFFFFBEB),
          border: Border.all(color: const Color(0xFF2DD4BF), width: 3),
          boxShadow: const [
            BoxShadow(
              color: Color(0x990D9488),
              blurRadius: 18,
              spreadRadius: 3,
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/images/asha-avatar.webp',
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.volunteer_activism,
                color: Color(0xFF0F766E),
                size: 30,
              ),
            ),
            Align(
              alignment: Alignment.bottomRight,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFF0F766E),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 4,
                    ),
                  ],
                ),
                child: const Text(
                  '👆',
                  style: TextStyle(fontSize: 14, height: 1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AshaSpotlightPainter extends CustomPainter {
  const _AshaSpotlightPainter({required this.targetRect});

  final Rect? targetRect;

  @override
  void paint(Canvas canvas, Size size) {
    final hole = targetRect?.inflate(8);
    final path = Path()..addRect(Offset.zero & size);
    if (hole != null) {
      path
        ..addRRect(RRect.fromRectAndRadius(hole, const Radius.circular(16)))
        ..fillType = PathFillType.evenOdd;
    }
    canvas.drawPath(
      path,
      Paint()..color = const Color(0x990F172A),
    );

    if (hole != null) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(hole, const Radius.circular(16)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = const Color(0xFF5EEAD4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.outer, 7),
      );
    }
  }

  @override
  bool shouldRepaint(_AshaSpotlightPainter oldDelegate) =>
      targetRect != oldDelegate.targetRect;
}
