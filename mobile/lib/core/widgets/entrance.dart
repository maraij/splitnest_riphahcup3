import 'dart:async';

import 'package:flutter/material.dart';

/// True when the platform asked for reduced motion (e.g. the OS
/// "reduce motion" / "remove animations" accessibility setting).
/// Animated widgets in this app check it and jump to their end state.
bool animationsDisabled(BuildContext context) =>
    MediaQuery.of(context).disableAnimations;

/// Subtle entrance: fade + slight slide-up on first mount.
/// Durations stay short (300ms) with smooth easing; [delay] staggers
/// a group of cards lightly (0–240ms). No flashing, no bouncing.
/// When reduced motion is on, the child renders immediately.
class Entrance extends StatefulWidget {
  const Entrance({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 300),
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  @override
  State<Entrance> createState() => _EntranceState();
}

class _EntranceState extends State<Entrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;

  /// The stagger timer. It MUST be cancelled in dispose: a
  /// below-the-fold Entrance can be disposed before its delay fires
  /// (e.g. a test ending, or a list rebuild), and an uncancelled
  /// Future.delayed leaves a pending timer behind.
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    final curve =
        CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    _opacity = Tween<double>(begin: 0, end: 1).animate(curve);
    _slide = Tween<Offset>(
      begin: const Offset(0, 0.03),
      end: Offset.zero,
    ).animate(curve);
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (animationsDisabled(context)) return widget.child;
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(
        position: _slide,
        child: widget.child,
      ),
    );
  }
}

/// Shared fade + slight slide-up transition for AnimatedSwitcher
/// (splash → login → home, and bottom-nav tab changes).
Widget fadeSlideTransition(
    Widget child, Animation<double> animation) {
  final slide = Tween<Offset>(
    begin: const Offset(0, 0.02),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
  return FadeTransition(
    opacity: animation,
    child: SlideTransition(position: slide, child: child),
  );
}
