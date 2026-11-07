import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../theme.dart';

/// Initials avatar in a fixed per-member colour, so each roommate is
/// recognisable at a glance. Colours are decorative only — balances are
/// always labelled with text as well.
///
/// If the member has picked a profile photo (AppState.profileImages,
/// keyed by member id, persisted in SharedPreferences), the photo is
/// shown here instead of the initials — so a photo set on Profile
/// updates EVERY avatar app-wide (Home, Settle Up, welcome popup,
/// login cards, shopping/expenses rows). With no photo, initials.
/// An explicit [imageBytes] overrides the stored photo (tests).
class MemberAvatar extends StatelessWidget {
  const MemberAvatar({
    super.key,
    required this.memberId,
    required this.name,
    this.radius = 20,
    this.selected = false,
    this.imageBytes,
  });

  final String memberId;
  final String name;
  final double radius;
  final bool selected;
  final Uint8List? imageBytes;

  static const _palette = {
    'M01': (SplitNestTheme.primary, Colors.white), // Ali — deep teal-green
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
    // Photo from the single source of truth (or an explicit override).
    // Priority: an explicit override, then the local bytes, then the
    // stored photo URL from the backend (Storage download URL, or a
    // local path once the store goes local) — the URL is what other
    // members' devices show. A broken URL falls back to initials.
    final state = context.watch<AppState>();
    final Uint8List? photo = imageBytes ?? state.profileImageFor(memberId);
    final String? photoUrl =
        photo == null ? state.profilePhotoUrlFor(memberId) : null;
    final Widget face;
    if (photo != null) {
      face = ClipOval(
        child: Image.memory(
          photo,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
        ),
      );
    } else if (photoUrl != null) {
      face = ClipOval(
        child: Image.network(
          photoUrl,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => CircleAvatar(
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
        ),
      );
    } else {
      face = CircleAvatar(
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
      );
    }
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
      child: face,
    );
  }
}
