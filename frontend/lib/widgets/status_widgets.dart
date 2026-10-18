import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// A colored status chip that ALWAYS pairs an icon with a text label —
/// never relies on color alone to communicate meaning (accessibility
/// requirement: no color-only status).
class StatusBadge extends StatelessWidget {
  final SafetyStatus status;
  final String? overrideLabel;

  const StatusBadge({super.key, required this.status, this.overrideLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md, vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: status.lightColor,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(status.icon, size: 16, color: status.color),
          const SizedBox(width: 6),
          Text(
            overrideLabel ?? status.label,
            style: TextStyle(
                color: status.color, fontWeight: FontWeight.w700, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

/// The primary Home-screen card answering "Is the elder safe?".
/// Every value shown here MUST be passed in from real backend/state —
/// this widget has no fallback demo data of its own.
class SafetyStatusCard extends StatelessWidget {
  final SafetyStatus status;
  final String elderName;
  final String?
      lastUpdatedLabel; // e.g. "Updated 12s ago" — caller formats real timestamp
  final double? riskScore; // null when backend hasn't provided one
  final String? message; // optional full status sentence, shown below the badge
  final String?
      riskLevel; // raw backend risk level label (e.g. LOW/MEDIUM/HIGH), shown as-is when riskScore isn't available

  const SafetyStatusCard({
    super.key,
    required this.status,
    required this.elderName,
    this.lastUpdatedLabel,
    this.riskScore,
    this.message,
    this.riskLevel,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                        color: AppColors.primaryLight, shape: BoxShape.circle),
                    child: const Icon(Icons.elderly,
                        color: AppColors.primary, size: 28),
                  ),
                const SizedBox(width: AppSpacing.lg),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(elderName,
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 2),
                      StatusBadge(status: status),
                    ],
                  ),
                ),
                if (riskScore != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        "${riskScore!.toStringAsFixed(0)}%",
                        style: Theme.of(context)
                            .textTheme
                            .headlineMedium
                            ?.copyWith(color: status.color),
                      ),
                      Text("Risk",
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
              ],
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(message!, style: Theme.of(context).textTheme.bodyMedium),
            ],
            if (riskLevel != null && riskScore == null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(riskLevel!,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
            if (lastUpdatedLabel != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(lastUpdatedLabel!,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// A compact summary card used for Activity / Location / Fall /
/// Environment / Vitals tiles on Home. Tapping navigates to the
/// corresponding detail screen (caller supplies onTap).
class SummaryCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String
      value; // caller MUST pass real data or "No data available" — never a default
  final VoidCallback? onTap;
  final bool dense;

  const SummaryCard({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.value,
    this.onTap,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconSize = dense ? 32.0 : 40.0;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.card),
        onTap: onTap,
        child: Padding(
          padding: dense
              ? const EdgeInsets.all(AppSpacing.md)
              : const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: iconSize,
                height: iconSize,
                decoration: BoxDecoration(
                    color: iconBg, borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: iconColor, size: dense ? 18 : 22),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(title, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 2),
              Expanded(
                child: Text(value,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Standard loading placeholder — use instead of showing demo values
/// while a real API call is in flight.
class LoadingState extends StatelessWidget {
  final String? message;
  const LoadingState({super.key, this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(color: AppColors.primary),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.lg),
              Text(message!, style: Theme.of(context).textTheme.bodyMedium),
            ],
          ],
        ),
      ),
    );
  }
}

/// Standard empty-state placeholder. NEVER fill this slot with fake
/// values — always show this widget when real data genuinely doesn't exist.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  const EmptyState({super.key, required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.textSecondary),
            const SizedBox(height: AppSpacing.lg),
            Text(message,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Standard error-state placeholder with a Retry action. Every
/// API-driven screen should be able to render this on failure rather
/// than crash or silently show nothing.
class ErrorStateView extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ErrorStateView(
      {super.key, required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40, color: AppColors.emergency),
            const SizedBox(height: AppSpacing.lg),
            Text(message,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: AppSpacing.lg),
            OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text("Retry")),
          ],
        ),
      ),
    );
  }
}

/// Persistent banner shown when the monitoring connection (WebSocket /
/// polling) is lost. Shows the real last-known-update time passed in
/// by the caller — never fabricates a timestamp.
class ConnectionLostBanner extends StatelessWidget {
  final String? lastUpdatedLabel;
  final VoidCallback onRetry;

  const ConnectionLostBanner(
      {super.key, this.lastUpdatedLabel, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.lg),
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      decoration: BoxDecoration(
          color: AppColors.warningLight,
          borderRadius: BorderRadius.circular(AppRadius.card)),
      child: Row(
        children: [
          const Icon(Icons.wifi_off, color: AppColors.warning),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text("Monitoring connection lost",
                    style: TextStyle(fontWeight: FontWeight.w700)),
                if (lastUpdatedLabel != null)
                  Text(lastUpdatedLabel!,
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          TextButton(onPressed: onRetry, child: const Text("Retry")),
        ],
      ),
    );
  }
}

