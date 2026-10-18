import 'package:flutter/material.dart';

/// Centralized breakpoints — per Section 41, screens should NOT
/// simply scale the mobile UI. These thresholds follow Material's own
/// guidance (600dp = tablet, 1024dp = desktop) rather than arbitrary
/// numbers, so every screen that uses this measures against the same
/// definition of "tablet" / "desktop".
class Breakpoints {
  Breakpoints._();
  static const tablet = 600.0;
  static const desktop = 1024.0;
}

enum DeviceType { mobile, tablet, desktop }

DeviceType deviceTypeOf(BuildContext context) {
  final width = MediaQuery.of(context).size.width;
  if (width >= Breakpoints.desktop) return DeviceType.desktop;
  if (width >= Breakpoints.tablet) return DeviceType.tablet;
  return DeviceType.mobile;
}

/// Wraps a screen's body so that on tablet/desktop widths the content
/// is constrained to a readable max width and centered, rather than
/// stretching a phone-shaped column across a full desktop browser
/// window. Mobile is passed through unchanged (full width).
///
/// Usage: wrap a screen's existing body in ResponsiveScaffoldBody —
/// this does not change what the body contains, only how wide it's
/// allowed to render.
class ResponsiveScaffoldBody extends StatelessWidget {
  final Widget child;
  final double maxWidthTablet;
  final double maxWidthDesktop;

  const ResponsiveScaffoldBody({
    super.key,
    required this.child,
    this.maxWidthTablet = 700,
    this.maxWidthDesktop = 960,
  });

  @override
  Widget build(BuildContext context) {
    final type = deviceTypeOf(context);
    if (type == DeviceType.mobile) return child;

    final maxWidth =
        type == DeviceType.desktop ? maxWidthDesktop : maxWidthTablet;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}

/// A grid that shows 2 columns on mobile (matching the existing
/// Home Dashboard grid), and widens to 3 or 4 columns on tablet/desktop
/// rather than leaving large empty gutters either side of a
/// phone-width 2-column grid stretched across a tablet screen.
class ResponsiveGrid extends StatelessWidget {
  final List<Widget> children;
  final double childAspectRatio;
  final double spacing;

  const ResponsiveGrid({
    super.key,
    required this.children,
    this.childAspectRatio = 1.05,
    this.spacing = 12,
  });

  @override
  Widget build(BuildContext context) {
    final type = deviceTypeOf(context);
    final columns = switch (type) {
      DeviceType.mobile => 2,
      DeviceType.tablet => 3,
      DeviceType.desktop => 4,
    };
    return GridView.count(
      crossAxisCount: columns,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: spacing,
      mainAxisSpacing: spacing,
      childAspectRatio: childAspectRatio,
      children: children,
    );
  }
}
