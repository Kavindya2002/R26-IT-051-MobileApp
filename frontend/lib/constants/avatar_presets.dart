import 'package:flutter/material.dart';

/// A single selectable preset avatar: an icon + a background color.
///
/// Using icon+color instead of bundled illustration images means:
///  - no new image assets to add to pubspec.yaml / ship in the app
///  - crisp at any screen density (vector, not raster)
///  - trivial to extend (just add another entry below)
///
/// `id` is what actually gets stored on the backend (users.avatar_id /
/// elders.avatar_id) — it must stay stable once used in production,
/// since existing rows will have it saved. Never reuse an id for a
/// different icon/color later; add a new id instead.
///
/// ADDED (illustrated avatar support): a preset can now be either
/// icon-based (`icon` set, `imagePath` null — the original design) or
/// image-based (`imagePath` set to a bundled asset, `icon` null).
/// `color` is still used for the image case too, as the circle's
/// background tint, so image avatars match the picker's visual style.
class AvatarPreset {
  final String id;
  final IconData? icon;
  final String? imagePath;
  final Color color;
  const AvatarPreset(this.id, this.icon, this.color, {this.imagePath});
  const AvatarPreset.image(this.id, this.imagePath, this.color) : icon = null;
}

class AvatarPresets {
  // ---------------------------------------------------------------
  // ELDER presets — shown when picking an avatar for an elder profile.
  // ---------------------------------------------------------------
  static const List<AvatarPreset> elder = [
    AvatarPreset('elder_1', Icons.elderly, Color(0xFF2E7D6B)),
    AvatarPreset('elder_2', Icons.elderly_woman, Color(0xFFC97B63)),
    AvatarPreset('elder_3', Icons.accessible, Color(0xFF5C6BC0)),
    AvatarPreset('elder_4', Icons.accessible_forward, Color(0xFF8E63CE)),
    AvatarPreset('elder_5', Icons.favorite, Color(0xFFE57373)),
    AvatarPreset('elder_6', Icons.spa, Color(0xFF66BB6A)),
    AvatarPreset('elder_7', Icons.park, Color(0xFF8D6E63)),
    AvatarPreset('elder_8', Icons.local_florist, Color(0xFFF06292)),
    AvatarPreset('elder_9', Icons.wb_sunny, Color(0xFFFFB300)),
    AvatarPreset('elder_10', Icons.home, Color(0xFF42A5F5)),
    // ADDED: the illustrated grandfather avatar the user supplied.
    // id stays 'elder_grandfather' forever once anyone picks it —
    // see the stability note on AvatarPreset.id above.
    AvatarPreset.image(
      'elder_grandfather',
      'assets/avatars/elder_grandfather.png',
      Color(0xFFDDB892),
    ),
    // ADDED: illustrated elder avatars from the user's own avatar pack.
    AvatarPreset.image(
        'elder_photo_2', 'assets/avatars/elder_photo_2.png', Color(0xFFB08968)),
    AvatarPreset.image(
        'elder_photo_3', 'assets/avatars/elder_photo_3.png', Color(0xFF8D99AE)),
    AvatarPreset.image(
        'elder_photo_4', 'assets/avatars/elder_photo_4.png', Color(0xFFC97B63)),
    AvatarPreset.image(
        'elder_photo_5', 'assets/avatars/elder_photo_5.png', Color(0xFF9D8189)),
    AvatarPreset.image(
        'elder_photo_6', 'assets/avatars/elder_photo_6.png', Color(0xFF7B8D8E)),
    AvatarPreset.image(
        'elder_photo_7', 'assets/avatars/elder_photo_7.png', Color(0xFF5C6B73)),
    AvatarPreset.image(
        'elder_photo_8', 'assets/avatars/elder_photo_8.png', Color(0xFF7A6C5D)),
  ];

  // ---------------------------------------------------------------
  // CAREGIVER / EMERGENCY PERSON presets — shown when picking an
  // avatar on the Edit Profile screen (used by both roles).
  // ---------------------------------------------------------------
  static const List<AvatarPreset> caregiver = [
    AvatarPreset('caregiver_1', Icons.support_agent, Color(0xFF2E7D6B)),
    AvatarPreset('caregiver_2', Icons.volunteer_activism, Color(0xFFEF5350)),
    AvatarPreset('caregiver_3', Icons.health_and_safety, Color(0xFF42A5F5)),
    AvatarPreset('caregiver_4', Icons.family_restroom, Color(0xFFFFA726)),
    AvatarPreset('caregiver_5', Icons.medical_services, Color(0xFF26A69A)),
    AvatarPreset('caregiver_6', Icons.favorite_border, Color(0xFFEC407A)),
    AvatarPreset('caregiver_7', Icons.shield, Color(0xFF5C6BC0)),
    AvatarPreset('caregiver_8', Icons.groups, Color(0xFF8D6E63)),
    AvatarPreset('caregiver_9', Icons.badge, Color(0xFF7E57C2)),
    AvatarPreset('caregiver_10', Icons.local_hospital, Color(0xFFEF6C00)),
    // ADDED: illustrated caregiver/emergency-person avatars from the
    // user's own avatar pack.
    AvatarPreset.image('caregiver_photo_1',
        'assets/avatars/caregiver_photo_1.png', Color(0xFF2A9D8F)),
    AvatarPreset.image('caregiver_photo_2',
        'assets/avatars/caregiver_photo_2.png', Color(0xFF264653)),
    AvatarPreset.image('caregiver_photo_3',
        'assets/avatars/caregiver_photo_3.png', Color(0xFF457B9D)),
    AvatarPreset.image('caregiver_photo_4',
        'assets/avatars/caregiver_photo_4.png', Color(0xFFE76F51)),
    AvatarPreset.image('caregiver_photo_5',
        'assets/avatars/caregiver_photo_5.png', Color(0xFFE07A5F)),
  ];

  static const List<AvatarPreset> all = [...elder, ...caregiver];

  /// Looks up a preset by its stored id. Returns null for an unknown
  /// or missing id so callers can fall back to an initial letter —
  /// this keeps old rows (created before this feature existed, or
  /// with avatar_id = null) displaying correctly with no crash.
  static AvatarPreset? find(String? id) {
    if (id == null) return null;
    for (final p in all) {
      if (p.id == id) return p;
    }
    return null;
  }
}
