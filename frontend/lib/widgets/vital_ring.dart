import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// The app's signature visual motif: a soft circular ring used
/// everywhere a bounded metric needs a glanceable read — fall
/// confidence, heart rate position within a healthy band, or
/// guidance step progress. Reusing one shape for all of these ties
/// the whole app together instead of every screen inventing its own
/// chart.
class VitalRing extends StatelessWidget {
  final double progress; // 0.0 - 1.0
  final Color color;
  final Widget center;
  final double size;
  final double strokeWidth;

  const VitalRing({
    super.key,
    required this.progress,
    required this.color,
    required this.center,
    this.size = 96,
    this.strokeWidth = 8,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: 1,
              strokeWidth: strokeWidth,
              color: AppColors.surfaceMuted,
            ),
          ),
          SizedBox(
            width: size,
            height: size,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: progress.clamp(0.0, 1.0)),
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => CircularProgressIndicator(
                value: value,
                strokeWidth: strokeWidth,
                color: color,
                strokeCap: StrokeCap.round,
              ),
            ),
          ),
          center,
        ],
      ),
    );
  }
}
