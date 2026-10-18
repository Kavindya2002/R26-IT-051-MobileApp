class Elder {
  final String id;
  final String name;
  final int age;
  final int previousFalls;
  final String assistiveDevice;
  final String? address;
  final String? phone;
  final String? gender;
  final String? userId;
  // ADDED (avatar picker feature): the id of a preset avatar chosen
  // in the Flutter app (e.g. "elder_1") — see
  // lib/constants/avatar_presets.dart for the fixed set of valid ids.
  // Null for any elder who hasn't picked one yet, which AvatarCircle
  // already treats as "show the initial-letter fallback".
  final String? avatarId;

  Elder({
    required this.id,
    required this.name,
    required this.age,
    required this.previousFalls,
    required this.assistiveDevice,
    this.address,
    this.phone,
    this.gender,
    this.userId,
    this.avatarId,
  });

  bool get hasAppAccess => userId != null && userId!.isNotEmpty;

  factory Elder.fromJson(Map<String, dynamic> json) => Elder(
        id: json["id"].toString(),
        name: json["name"] ?? "Unnamed",
        age: json["age"] ?? 0,
        previousFalls: json["previous_falls"] ?? 0,
        assistiveDevice: json["assistive_device"] ?? "none",
        address: json["address"],
        phone: json["phone"],
        gender: json["gender"],
        userId: json["user_id"]?.toString(),
        avatarId: json["avatar_id"],
      );

  Map<String, dynamic> toJson() => {
        "name": name,
        "age": age,
        "previous_falls": previousFalls,
        "assistive_device": assistiveDevice,
        "address": address,
        "phone": phone,
        "gender": gender,
        "user_id": userId,
        "avatar_id": avatarId,
      };
}
