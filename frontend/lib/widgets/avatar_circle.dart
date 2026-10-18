import 'package:flutter/material.dart';
import '../constants/avatar_presets.dart';

/// Displays an avatar: a chosen preset icon if `avatarId` resolves to
/// one, otherwise falls back to the existing initial-letter circle
/// behavior (so profiles created before this feature, or with no
/// avatar chosen yet, look exactly as they did before).
class AvatarCircle extends StatelessWidget {
  final String? avatarId;
  final String fallbackInitial;
  final double radius;
  final Color fallbackColor;

  const AvatarCircle({
    super.key,
    required this.avatarId,
    required this.fallbackInitial,
    this.radius = 26,
    this.fallbackColor = const Color(0xFF2E7D6B),
  });

  @override
  Widget build(BuildContext context) {
    final preset = AvatarPresets.find(avatarId);
    if (preset != null) {
      // ADDED (illustrated avatar support): an image-based preset
      // fills the whole circle with its picture instead of an icon.
      if (preset.imagePath != null) {
        return CircleAvatar(
          radius: radius,
          backgroundColor: preset.color.withValues(alpha: 0.15),
          backgroundImage: AssetImage(preset.imagePath!),
        );
      }
      return CircleAvatar(
        radius: radius,
        backgroundColor: preset.color.withValues(alpha: 0.15),
        child: Icon(preset.icon, color: preset.color, size: radius * 0.95),
      );
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: fallbackColor.withValues(alpha: 0.15),
      child: Text(
        fallbackInitial,
        style: TextStyle(
          color: fallbackColor,
          fontWeight: FontWeight.w700,
          fontSize: radius * 0.7,
        ),
      ),
    );
  }
}
