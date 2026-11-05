import 'package:flutter/material.dart';

/// Initials avatar in a fixed per-member colour, so each roommate is
/// recognisable at a glance. Colours are decorative only — balances are
/// always labelled with text as well.
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.memberId,
    required this.name,
    this.radius = 20,
    this.selected = false,
  });

  final String memberId;
  final String name;
  final double radius;
  final bool selected;

  static const _palette = {
    'M01': (Color(0xFF0F766E), Colors.white), // Ali — teal
    'M02': (Color(0xFF9D174D), Colors.white), // Ayesha — rose
    'M03': (Color(0xFFB45309), Colors.white), // Bilal — gold-amber
  };

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first)
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _palette[memberId] ??
        (Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.onPrimary);
    return Container(
      decoration: selected
          ? BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                  color: Theme.of(context).colorScheme.primary, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: bg.withValues(alpha: 0.35),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            )
          : null,
      child: CircleAvatar(
        radius: radius,
        backgroundColor: bg,
        foregroundColor: fg,
        child: Text(
          _initials,
          style: TextStyle(
            fontSize: radius * 0.75,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
      ),
    );
  }
}
