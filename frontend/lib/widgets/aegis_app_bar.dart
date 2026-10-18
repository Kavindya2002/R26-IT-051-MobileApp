import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// The navy "AegisCare" header used on every screen. Shows the back
/// button automatically when there's something to pop back to.
class AegisAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final List<Widget>? actions;
  final bool showLogo;

  const AegisAppBar(
      {super.key, this.title, this.actions, this.showLogo = true});

  @override
  Widget build(BuildContext context) {
    return AppBar(
      backgroundColor: AppColors.navy,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 30,
            height: 30,
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
                color: Colors.white, borderRadius: BorderRadius.circular(9)),
            child: Image.asset(
              'assets/images/aegiscare_logo.png',
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Icon(
                  Icons.health_and_safety_rounded,
                  color: AppColors.primary,
                  size: 16),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: showLogo
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RichText(
                        text: const TextSpan(
                          children: [
                            TextSpan(
                                text: "Aegis",
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 18)),
                            TextSpan(
                                text: "Care",
                                style: TextStyle(
                                    color: AppColors.cyan,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 18)),
                          ],
                        ),
                      ),
                      const Text("Elder Care & Safety",
                          style: TextStyle(
                              color: Color(0xFF9AA5CE), fontSize: 10)),
                    ],
                  )
                : Text(title ?? ""),
          ),
        ],
      ),
      actions: actions,
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}