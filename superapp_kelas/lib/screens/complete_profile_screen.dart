import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../utils/qr_scanner_helper.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

// ----------------------------------------------------------------------
// FITUR "Lengkapi Profil Dosen/Mahasiswa": layar ini dibuka SETELAH login
// (lewat ikon profil di topbar Beranda), berisi field-field akademik
// tambahan yang berbeda untuk Dosen vs Mahasiswa:
//   - Dosen: NIDN/NIP, Fakultas, Program Studi, Nomor HP, Foto Profil
//   - Mahasiswa: Program Studi, Fakultas, Angkatan, Nomor HP, Foto Profil
//     (NIM sudah diisi saat registrasi, tapi tetap bisa diedit di sini)
// ----------------------------------------------------------------------
class CompleteProfileScreen extends StatefulWidget {
  const CompleteProfileScreen({super.key});

  @override
  State<CompleteProfileScreen> createState() => _CompleteProfileScreenState();
}

class _CompleteProfileScreenState extends State<CompleteProfileScreen> {
  late final TextEditingController _nidnNipCtrl;
  late final TextEditingController _nimCtrl;
  late final TextEditingController _fakultasCtrl;
  late final TextEditingController _prodiCtrl;
  late final TextEditingController _angkatanCtrl;
  late final TextEditingController _hpCtrl;
  bool _uploadingAvatar = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final user = context.read<AuthProvider>().user ?? {};
    _nidnNipCtrl = TextEditingController(text: user['nidn_nip']?.toString() ?? '');
    _nimCtrl = TextEditingController(text: user['nim']?.toString() ?? '');
    _fakultasCtrl = TextEditingController(text: user['fakultas']?.toString() ?? '');
    _prodiCtrl = TextEditingController(text: user['program_studi']?.toString() ?? '');
    _angkatanCtrl = TextEditingController(text: user['angkatan']?.toString() ?? '');
    _hpCtrl = TextEditingController(text: user['nomor_hp']?.toString() ?? '');
  }

  @override
  void dispose() {
    _nidnNipCtrl.dispose();
    _nimCtrl.dispose();
    _fakultasCtrl.dispose();
    _prodiCtrl.dispose();
    _angkatanCtrl.dispose();
    _hpCtrl.dispose();
    super.dispose();
  }

  Future<void> _showAvatarSelectionModal() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(22),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.camera_alt_rounded, color: _kNavyDark, size: 22),
                SizedBox(width: 10),
                Text(
                  'Ubah Foto Profil (Close-Up)',
                  style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Pilih metode untuk mengambil atau mengunggah foto profil Anda:',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 18),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFEFF6FF), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.camera_front_rounded, color: Color(0xFF1D4ED8)),
              ),
              title: const Text('Ambil Foto Selfie (Kamera Langsung)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kNavyDark)),
              subtitle: const Text('Gunakan kamera webcam perangkat untuk mengambil foto close-up seketika', style: TextStyle(fontSize: 11, color: Colors.black54)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE2E8F0))),
              onTap: () {
                Navigator.pop(ctx);
                _captureAndUploadSelfie();
              },
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: const Color(0xFFF0FDF4), borderRadius: BorderRadius.circular(12)),
                child: const Icon(Icons.photo_library_rounded, color: Color(0xFF047857)),
              ),
              title: const Text('Unggah File dari Komputer / Galeri', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: _kNavyDark)),
              subtitle: const Text('Pilih file gambar JPEG/PNG dari penyimpanan perangkat Anda', style: TextStyle(fontSize: 11, color: Colors.black54)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: Color(0xFFE2E8F0))),
              onTap: () {
                Navigator.pop(ctx);
                _pickAndUploadAvatar();
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  Future<void> _captureAndUploadSelfie() async {
    final bytes = await QrScannerHelper.captureSelfiePhoto();
    if (bytes == null || bytes.isEmpty) return;

    if (!mounted) return;
    setState(() => _uploadingAvatar = true);
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.uploadAvatar(bytes, 'selfie_${DateTime.now().millisecondsSinceEpoch}.jpg');
    if (!mounted) return;
    setState(() => _uploadingAvatar = false);

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Foto profil selfie berhasil diperbarui!'), backgroundColor: Color(0xFF059669)),
      );
    } else if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authProvider.errorMessage ?? 'Gagal menyimpan foto selfie')),
      );
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    final result = await FilePicker.pickFiles(type: FileType.image, withData: true);
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;

    setState(() => _uploadingAvatar = true);
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.uploadAvatar(file.bytes!, file.name);
    if (!mounted) return;
    setState(() => _uploadingAvatar = false);

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Foto profil berhasil diunggah!'), backgroundColor: Color(0xFF059669)),
      );
    } else if (!success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authProvider.errorMessage ?? 'Gagal upload foto profil')),
      );
    }
  }

  Future<void> _handleSave(bool isDosen) async {
    setState(() => _saving = true);
    final authProvider = context.read<AuthProvider>();
    final fields = <String, dynamic>{
      'fakultas': _fakultasCtrl.text.trim(),
      'program_studi': _prodiCtrl.text.trim(),
      'nomor_hp': _hpCtrl.text.trim(),
      if (isDosen) 'nidn_nip': _nidnNipCtrl.text.trim(),
      if (!isDosen) 'nim': _nimCtrl.text.trim(),
      if (!isDosen) 'angkatan': _angkatanCtrl.text.trim(),
    };
    final success = await authProvider.updateProfile(fields);
    if (!mounted) return;
    setState(() => _saving = false);

    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('✅ Profil berhasil disimpan!'), backgroundColor: _kNavyDark),
      );
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authProvider.errorMessage ?? 'Gagal menyimpan profil')),
      );
    }
  }

  InputDecoration _fieldDecoration({required String label, required IconData icon}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.black54),
      prefixIcon: Icon(icon, color: _kNavyDark),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _kNavyDark, width: 1.5)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: _kMustardYellow, width: 2.5)),
      filled: true,
      fillColor: Colors.white,
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final user = authProvider.user ?? {};
    final isDosen = user['role'] == 'dosen';

    return Scaffold(
      backgroundColor: _kCreamBg,
      appBar: AppBar(
        backgroundColor: _kCreamBg,
        elevation: 0,
        foregroundColor: _kNavyDark,
        title: Text('Lengkapi Profil ${isDosen ? "Dosen" : "Mahasiswa"}', style: const TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _kNavyDark, width: 2),
                boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // FOTO PROFIL (CLOSE-UP)
                  Center(
                    child: Tooltip(
                      message: 'Klik untuk ubah foto profil (Upload / Selfie)',
                      child: GestureDetector(
                        onTap: _uploadingAvatar ? null : _showAvatarSelectionModal,
                        child: Stack(
                          children: [
                            CircleAvatar(
                              radius: 44,
                              backgroundColor: _kMustardYellow,
                              backgroundImage: (user['avatar_url'] != null && user['avatar_url'].toString().isNotEmpty)
                                  ? NetworkImage(ApiService.getFullMediaUrl(user['avatar_url'])!)
                                  : null,
                              child: (user['avatar_url'] == null || user['avatar_url'].toString().isEmpty)
                                  ? const Icon(Icons.person, color: _kNavyDark, size: 44)
                                  : null,
                            ),
                            if (_uploadingAvatar)
                              const Positioned.fill(
                                child: CircleAvatar(
                                  radius: 44,
                                  backgroundColor: Colors.black45,
                                  child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                                ),
                              ),
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(color: _kNavyDark, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                                child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 16),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Center(child: Text('Foto Profil (Close-Up)', style: TextStyle(color: _kNavyDark, fontSize: 13, fontWeight: FontWeight.w800))),
                  const Center(child: Text('Klik foto di atas untuk Upload atau Selfie Kamera', style: TextStyle(color: Colors.black54, fontSize: 11))),
                  const SizedBox(height: 24),

                  if (isDosen) ...[
                    TextField(controller: _nidnNipCtrl, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'NIDN/NIP', icon: Icons.badge_outlined)),
                    const SizedBox(height: 16),
                    TextField(controller: _fakultasCtrl, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'Fakultas', icon: Icons.account_balance_outlined)),
                    const SizedBox(height: 16),
                    TextField(controller: _prodiCtrl, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'Program Studi', icon: Icons.menu_book_outlined)),
                    const SizedBox(height: 16),
                    TextField(controller: _hpCtrl, keyboardType: TextInputType.phone, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'Nomor HP', icon: Icons.phone_outlined)),
                  ] else ...[
                    TextField(controller: _nimCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'NIM', icon: Icons.badge_outlined)),
                    const SizedBox(height: 16),
                    TextField(controller: _prodiCtrl, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'Program Studi', icon: Icons.menu_book_outlined)),
                    const SizedBox(height: 16),
                    TextField(controller: _fakultasCtrl, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'Fakultas', icon: Icons.account_balance_outlined)),
                    const SizedBox(height: 16),
                    TextField(controller: _angkatanCtrl, keyboardType: TextInputType.number, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'Angkatan', icon: Icons.event_outlined)),
                    const SizedBox(height: 16),
                    TextField(controller: _hpCtrl, keyboardType: TextInputType.phone, style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold), decoration: _fieldDecoration(label: 'Nomor HP', icon: Icons.phone_outlined)),
                  ],

                  const SizedBox(height: 24),
                  SizedBox(
                    height: 48,
                    child: ElevatedButton(
                      onPressed: _saving ? null : () => _handleSave(isDosen),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kNavyDark,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: const BorderSide(color: _kNavyDark, width: 1.5)),
                      ),
                      child: _saving
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('💾 Simpan Profil', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
