import 'package:flutter/material.dart';
import '../constants/avatar_presets.dart';
import '../services/api_service.dart';
import '../theme/app_theme.dart';
import '../widgets/aegis_app_bar.dart';
import '../widgets/avatar_circle.dart';
import '../widgets/avatar_picker_sheet.dart';

class EditProfileScreen extends StatefulWidget {
  final Map<String, dynamic> user;
  const EditProfileScreen({super.key, required this.user});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _phoneCtrl;
  late final TextEditingController _relationshipCtrl;
  late final TextEditingController _addressCtrl;
  late final TextEditingController _priorityCtrl;
  // ADDED (avatar picker feature): tracks the selected preset id so it
  // can be shown immediately (optimistic) and sent along with the rest
  // of the form on save. Starts from whatever is already saved on this
  // user (null for any profile that predates this feature).
  String? _avatarId;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.user["name"] ?? "");
    _phoneCtrl = TextEditingController(text: widget.user["phone"] ?? "");
    _relationshipCtrl =
        TextEditingController(text: widget.user["relationship"] ?? "");
    _addressCtrl = TextEditingController(text: widget.user["address"] ?? "");
    _priorityCtrl =
        TextEditingController(text: "${widget.user["priority"] ?? 1}");
    _avatarId = widget.user["avatar_id"] as String?;
  }

  Future<void> _pickAvatar() async {
    final picked = await showAvatarPicker(
      context,
      presets: AvatarPresets.caregiver,
      currentId: _avatarId,
    );
    if (picked != null) setState(() => _avatarId = picked);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiService.instance.updateMyProfile({
        "name": _nameCtrl.text.trim(),
        "phone": _phoneCtrl.text.trim(),
        "relationship": _relationshipCtrl.text.trim().isEmpty
            ? null
            : _relationshipCtrl.text.trim(),
        "address":
            _addressCtrl.text.trim().isEmpty ? null : _addressCtrl.text.trim(),
        "priority": int.tryParse(_priorityCtrl.text.trim()) ?? 1,
        // ADDED (avatar picker feature): omitted entirely (stays null)
        // when the user never picked one, so UpdateUserRequest's
        // "only update fields that aren't null" logic leaves whatever
        // was already saved untouched rather than clearing it.
        if (_avatarId != null) "avatar_id": _avatarId,
      });
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = _nameCtrl.text.trim();
    final initial = name.isNotEmpty ? name[0].toUpperCase() : "?";

    return Scaffold(
      appBar: AegisAppBar(showLogo: false, title: "Edit profile"),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ADDED (avatar picker feature): tap the avatar to open
                // the preset picker. A small pencil badge communicates
                // it's tappable without needing an extra button.
                Center(
                  child: GestureDetector(
                    onTap: _pickAvatar,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        AvatarCircle(
                          avatarId: _avatarId,
                          fallbackInitial: initial,
                          radius: 44,
                          fallbackColor: AppColors.primary,
                        ),
                        Positioned(
                          bottom: -2,
                          right: -2,
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: const Icon(Icons.edit,
                                size: 14, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: _pickAvatar,
                    child: const Text("Change avatar"),
                  ),
                ),
                const SizedBox(height: 10),
                TextFormField(
                  controller: _nameCtrl,
                  decoration: const InputDecoration(labelText: "Full name"),
                  onChanged: (_) => setState(() {}), // keeps the fallback initial live
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? "Enter a name"
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _phoneCtrl,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: "Phone"),
                  validator: (v) => (v == null || v.trim().length < 9)
                      ? "Enter a valid phone"
                      : null,
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _relationshipCtrl,
                  decoration:
                      const InputDecoration(labelText: "Relationship to elder"),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _priorityCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: "Emergency contact priority",
                    helperText:
                        "1 = contacted first if multiple people are registered",
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _addressCtrl,
                  decoration: const InputDecoration(labelText: "Address"),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 14),
                  Text(_error!,
                      style: const TextStyle(color: AppColors.emergency)),
                ],
                const SizedBox(height: 28),
                ElevatedButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Save changes"),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
