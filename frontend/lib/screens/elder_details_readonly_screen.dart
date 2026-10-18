import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/avatar_circle.dart';

/// Emergency Person's view of an elder's profile — no Edit/Delete
/// icons, no Previous Falls (sensitive model-input data), and no
/// Emergency Contacts management, unlike the Caregiver's version.
class ElderDetailsReadOnlyScreen extends StatelessWidget {
  final Map<String, dynamic> elder;
  const ElderDetailsReadOnlyScreen({super.key, required this.elder});

  @override
  Widget build(BuildContext context) {
    final name = elder["name"]?.toString() ?? "Unknown";
    final age = elder["age"]?.toString() ?? "-";
    final address = elder["address"]?.toString() ?? "Not provided";
    final assistiveDevice = elder["assistive_device"]?.toString();
    // ADDED (avatar picker feature): shows the elder's chosen preset
    // avatar when one is set, falling back to the exact original
    // behavior — an initial-letter circle — when it isn't.
    final avatarId = elder["avatar_id"]?.toString();

    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Elder Details"),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  AvatarCircle(
                    avatarId: avatarId,
                    fallbackInitial: name.isNotEmpty ? name[0].toUpperCase() : "?",
                    radius: 38,
                    fallbackColor: AppColors.info,
                  ),
                  const SizedBox(height: 12),
                  Text(name, style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE1EAFB),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.visibility_outlined,
                            color: AppColors.accentBlue, size: 12),
                        SizedBox(width: 4),
                        Text("View only",
                            style: TextStyle(
                                color: AppColors.accentBlue,
                                fontWeight: FontWeight.w700,
                                fontSize: 11)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  _row(context, "Age", "$age years"),
                  const Divider(height: 1),
                  if (assistiveDevice != null) ...[
                    _row(context, "Assistive Device", assistiveDevice),
                    const Divider(height: 1),
                  ],
                  _row(context, "Home Address", address),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      color: AppColors.textMuted, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "You're viewing this profile as an emergency contact. Editing is managed by the primary caregiver.",
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Text(value,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.left),
          ),
        ],
      ),
    );
  }
}
