import 'package:flutter/material.dart';
import '../constants/avatar_presets.dart';

/// Opens a bottom sheet grid of preset avatars and resolves with the
/// chosen avatar id, or null if the sheet was dismissed without a
/// pick (caller should keep the previous avatar_id in that case).
///
/// Usage:
///   final picked = await showAvatarPicker(
///     context,
///     presets: AvatarPresets.caregiver, // or AvatarPresets.elder
///     currentId: _avatarId,
///   );
///   if (picked != null) setState(() => _avatarId = picked);
Future<String?> showAvatarPicker(
  BuildContext context, {
  required List<AvatarPreset> presets,
  String? currentId,
  String title = "Choose an avatar",
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      // FIX (overflow bug): with isScrollControlled, this builder has no
      // height limit of its own, so once the preset grid needs more than
      // ~3 rows (more presets than the original design budgeted for —
      // e.g. the elder preset list) the sheet's natural height exceeds
      // the screen and Flutter reports "BOTTOM OVERFLOWED BY n PIXELS"
      // instead of scrolling. Capping the sheet at 85% of the screen
      // height and wrapping its content in a SingleChildScrollView lets
      // it scroll instead of overflowing — nothing else about the
      // layout, spacing, or grid changes.
      final maxSheetHeight = MediaQuery.of(sheetContext).size.height * 0.85;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxSheetHeight),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(sheetContext).textTheme.titleMedium),
                const SizedBox(height: 18),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  // FIX (overflow bug #2): each grid cell is laid out as a
                  // square by default (childAspectRatio: 1.0), giving a
                  // ~71x71 cell. A selected avatar's circle (56px) plus the
                  // checkmark row below it (SizedBox 4 + Icon 14 = 18px)
                  // needs ~74px of height, which overflows a square cell by
                  // a few pixels ("BOTTOM OVERFLOWED BY 3.0 PIXELS"). Making
                  // cells slightly taller than wide gives the checkmark row
                  // enough room without changing spacing, icon sizes, or
                  // anything else about the grid.
                  childAspectRatio: 0.78,
                  children: presets.map((p) {
                  final selected = p.id == currentId;
                  return InkWell(
                    borderRadius: BorderRadius.circular(32),
                    onTap: () => Navigator.of(sheetContext).pop(p.id),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ADDED (illustrated avatar support): an
                        // image-based preset shows its picture with a
                        // colored ring when selected, instead of a
                        // filled icon background.
                        if (p.imagePath != null)
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: p.color.withValues(alpha: 0.15),
                            backgroundImage: AssetImage(p.imagePath!),
                            child: selected
                                ? Container(
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border:
                                          Border.all(color: p.color, width: 3),
                                    ),
                                  )
                                : null,
                          )
                        else
                          CircleAvatar(
                            radius: 28,
                            backgroundColor: selected
                                ? p.color
                                : p.color.withValues(alpha: 0.15),
                            child: Icon(
                              p.icon,
                              color: selected ? Colors.white : p.color,
                              size: 26,
                            ),
                          ),
                        if (selected) ...[
                          const SizedBox(height: 4),
                          Icon(Icons.check_circle, size: 14, color: p.color),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
