import 'package:flutter/foundation.dart';

/// Holds the most recent Component 4 (Alert) result so the Home
/// Dashboard banner and the Alert Detail Screen can both read the
/// same data without re-fetching. Deliberately separate from
/// GuidanceState - an alert can exist without guidance (MEDIUM/HIGH
/// risk), and guidance is driven by its own independent gating rule.
class AlertState extends ChangeNotifier {
  String? alertType; // "Voice Alert" | "Caregiver Alert" | "Emergency Alert"
  double? confidence;
  Map<String, dynamic>? probabilities;
  String? fallType;
  String? riskLevel;
  String? location;
  String? elderPhone;
  DateTime? occurredAt;
  bool resolved = false;

  bool get hasActiveAlert => alertType != null && !resolved;

  void setAlert({
    required String alertType,
    required double confidence,
    required Map<String, dynamic> probabilities,
    required String fallType,
    required String riskLevel,
    required String location,
    String? elderPhone,
  }) {
    this.alertType = alertType;
    this.confidence = confidence;
    this.probabilities = probabilities;
    this.fallType = fallType;
    this.riskLevel = riskLevel;
    this.location = location;
    this.elderPhone = elderPhone;
    occurredAt = DateTime.now();
    resolved = false;
    notifyListeners();
  }

  void markResolved() {
    resolved = true;
    notifyListeners();
  }

  void clear() {
    alertType = null;
    confidence = null;
    probabilities = null;
    fallType = null;
    riskLevel = null;
    location = null;
    elderPhone = null;
    occurredAt = null;
    resolved = false;
    notifyListeners();
  }
}
