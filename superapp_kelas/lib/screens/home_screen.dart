import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_service.dart';
import '../utils/qr_scanner_helper.dart';
import 'login_screen.dart';
import 'quizizz/quizizz_screen.dart';
import 'class/class_screen.dart';
import 'complete_profile_screen.dart';
import '../widgets/classly_logo.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

// App Pastel Theme Colors
class AppThemeToken {
  final String name;
  final String category;
  final String desc;
  final IconData icon;
  final Color pastelBg;
  final Color textIconColor;

  const AppThemeToken({
    required this.name,
    required this.category,
    required this.desc,
    required this.icon,
    required this.pastelBg,
    required this.textIconColor,
  });
}

final List<AppThemeToken> _appTokens = [
  const AppThemeToken(
    name: 'Classly',
    category: 'Kuis & PR',
    desc: 'Mode Kuis Interaktif & Pekerjaan Rumah',
    icon: Icons.quiz_rounded,
    pastelBg: Color(0xFF6EA2B3), // Pastel Purple
    textIconColor: Color(0xFF0A4174),
  ),
];

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _uploadingAvatar = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

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

    if (!mounted) return;
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
        SnackBar(content: Text(authProvider.errorMessage ?? 'Gagal upload avatar')),
      );
    }
  }

  void _navigateToApp(String appName) {
    if (appName == 'Classly') {
      // PENTING (fitur "Manajemen Kelas"): sebelum masuk ke modul Classly,
      // dosen/mahasiswa WAJIB lewat Dashboard Kelas dulu -- dosen memilih
      // kelas mana yang mau dikelola, mahasiswa wajib join/pilih kelas
      // sebelum bisa mengakses konten kuis/PR/presentasi apapun.
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ClassDashboardScreen()));
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();
    final user = authProvider.user;

    final filteredApps = _appTokens.where((app) {
      final matchesQuery = _searchQuery.isEmpty ||
          app.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          app.desc.toLowerCase().contains(_searchQuery.toLowerCase());
      return matchesQuery;
    }).toList();

    // PENTING: layout lama (sidebar kiri kosong + panel kanan terpisah)
    // dihapus total karena setelah bagian-bagian dalamnya dihilangkan,
    // panel-panel itu jadi kotak kosong yang memboroskan ruang layar.
    // Sekarang semua (logo, profil, tombol Gabung/Buat Sesi) digabung
    // jadi SATU top bar ringkas, dan konten utama memakai lebar layar
    // secara maksimal (dengan batas lebar nyaman di layar besar) supaya
    // tetap terasa rapi dan tidak melebar berlebihan.
    return Scaffold(
      backgroundColor: _kCreamBg,
      body: Stack(
        children: [
          // ABSTRACT RETRO DECORATIVE SHAPES (Kuning Mustard Blobs)
          Positioned(
            top: -60,
            left: -60,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: _kMustardYellow.withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            right: -50,
            child: Container(
              width: 260,
              height: 260,
              decoration: BoxDecoration(
                color: _kMustardYellow.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
            ),
          ),

          // MAIN DASHBOARD LAYOUT
          SafeArea(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  // Batas lebar nyaman di layar besar (tidak melebar sampai
                  // ujung layar penuh), tapi tetap terasa "maksimal"
                  // dibanding layout lama yang menyisakan kotak kosong.
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildTopBar(context, user),
                        const SizedBox(height: 20),

                        // SEARCH BAR
                        _buildSearchBar(),
                        const SizedBox(height: 24),

                        // SECTION TITLE + CTA GABUNG/BUAT SESI SEJAJAR
                        LayoutBuilder(
                          builder: (ctx, constraints) {
                            final isNarrow = constraints.maxWidth < 520;
                            final title = const Text(
                              'Pilih Modul Pembelajaran Active',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _kNavyDark),
                            );
                            final cta = _buildJoinSessionButton(compact: isNarrow);
                            if (isNarrow) {
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [title, const SizedBox(height: 12), cta],
                              );
                            }
                            return Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [Flexible(child: title), const SizedBox(width: 12), cta],
                            );
                          },
                        ),
                        const SizedBox(height: 16),

                        // CARDS SESI / AKTIVITAS
                        if (filteredApps.isEmpty)
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(40),
                              child: Text('Tidak ada modul yang cocok dengan pencarian.', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold)),
                            ),
                          )
                        else
                          Wrap(
                            spacing: 18,
                            runSpacing: 18,
                            children: filteredApps.map((app) {
                              return SizedBox(
                                width: 420,
                                height: 300,
                                child: _RetroAppCard(
                                  token: app,
                                  onTap: () => _navigateToApp(app.name),
                                ),
                              );
                            }).toList(),
                          ),

                        const SizedBox(height: 28),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ----------------------------------------------------------------------
  // TOP BAR (LOGO + PROFIL PENGGUNA + LOGOUT) — MENGGABUNGKAN sidebar &
  // panel kanan yang lama jadi satu bar ringkas, responsif untuk layar
  // sempit maupun lebar.
  // ----------------------------------------------------------------------
  Widget _buildTopBar(BuildContext context, Map<String, dynamic>? user) {
    final isDosen = user?['role'] == 'dosen';

    final logo = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // FITUR "Rebranding Classly": logo Classly di topbar,
        // menggantikan ikon placeholder & nama "Superapp Kelas" lama.
        Container(
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: _kMustardYellow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: _kNavyDark, width: 1.5),
          ),
          child: const ClasslyLogo(size: 28),
        ),
        const SizedBox(width: 10),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Classly', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
            Text('Academic Edition', style: TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
          ],
        ),
      ],
    );

    final profile = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Tooltip(
          message: 'Klik untuk ubah foto profil (Upload / Selfie)',
          child: GestureDetector(
            onTap: _uploadingAvatar ? null : _showAvatarSelectionModal,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CircleAvatar(
                  radius: 22,
                  backgroundColor: _kMustardYellow,
                  backgroundImage: (user?['avatar_url'] != null && user!['avatar_url'].toString().isNotEmpty)
                      ? NetworkImage(ApiService.getFullMediaUrl(user['avatar_url'])!)
                      : null,
                  child: (user?['avatar_url'] == null || user!['avatar_url'].toString().isEmpty)
                      ? const Icon(Icons.person, color: _kNavyDark, size: 24)
                      : null,
                ),
                if (_uploadingAvatar)
                  const Positioned.fill(
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: Colors.black45,
                      child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                    ),
                  )
                else
                  Positioned(
                    bottom: -2,
                    right: -2,
                    child: Container(
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: _kNavyDark,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 1.5),
                      ),
                      child: const Icon(Icons.camera_alt_rounded, color: Colors.white, size: 10),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              user?['full_name'] ?? 'Pengguna',
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: _kNavyDark),
              overflow: TextOverflow.ellipsis,
            ),
            Container(
              margin: const EdgeInsets.only(top: 2),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _kMustardYellow,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _kNavyDark, width: 1),
              ),
              child: Text(
                isDosen ? '🎓 DOSEN' : '👨‍🎓 MAHASISWA',
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900, color: _kNavyDark),
              ),
            ),
          ],
        ),
        const SizedBox(width: 6),
        // FITUR "Lengkapi Profil Dosen/Mahasiswa" (poin 2 & 3): akses ke
        // layar lengkapi/edit profil (NIDN-NIP/NIM, Fakultas, Program
        // Studi, Angkatan, Nomor HP, Foto Profil), dibuka setelah login
        // lewat topbar ini.
        IconButton(
          icon: const Icon(Icons.badge_outlined, color: _kNavyDark, size: 20),
          tooltip: 'Lengkapi Profil',
          onPressed: () {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CompleteProfileScreen()));
          },
        ),
        IconButton(
          icon: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
          tooltip: 'Logout',
          onPressed: () async {
            await context.read<AuthProvider>().logout();
            if (mounted) {
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
            }
          },
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: _kNavyDark, width: 2),
        boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final isNarrow = constraints.maxWidth < 480;
          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [logo, const SizedBox(height: 14), profile],
            );
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [logo, profile],
          );
        },
      ),
    );
  }

  // ----------------------------------------------------------------------
  // TOMBOL "GABUNG / BUAT SESI" (dulu terkurung di panel kanan terpisah,
  // sekarang jadi CTA sejajar dengan judul section supaya tetap mudah
  // ditemukan tanpa menyisakan kotak kosong).
  // ----------------------------------------------------------------------
  Widget _buildJoinSessionButton({bool compact = false}) {
    return SizedBox(
      width: compact ? double.infinity : null,
      height: 46,
      child: ElevatedButton.icon(
        onPressed: () {},
        style: ElevatedButton.styleFrom(
          backgroundColor: _kNavyDark,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(30),
            side: const BorderSide(color: _kNavyDark, width: 1.5),
          ),
          elevation: 0,
        ),
        icon: const Icon(Icons.add_circle_rounded, color: _kMustardYellow, size: 20),
        label: const Text('Gabung / Buat Sesi', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
      ),
    );
  }

  // ----------------------------------------------------------------------
  // SEARCH BAR (ROUNDED-FULL WITH THIN NAVY OUTLINE)
  // ----------------------------------------------------------------------
  Widget _buildSearchBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: _kNavyDark, width: 1.5),
        boxShadow: const [
          BoxShadow(color: _kNavyDark, offset: Offset(2, 2), blurRadius: 0),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.search_rounded, color: _kNavyDark, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (val) => setState(() => _searchQuery = val),
              style: const TextStyle(color: _kNavyDark, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                hintText: 'Cari kelas, kuis, atau sesi...',
                hintStyle: TextStyle(color: Colors.black45, fontSize: 14),
                border: InputBorder.none,
              ),
            ),
          ),
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear, size: 18, color: _kNavyDark),
              onPressed: () {
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            ),
        ],
      ),
    );
  }
}

// ======================================================================
// RETRO APP CARD (SOLID 2PX NAVY OUTLINE + PASTEL BADGE + RETRO SHADOW)
// ======================================================================
class _RetroAppCard extends StatelessWidget {
  final AppThemeToken token;
  final VoidCallback onTap;

  const _RetroAppCard({required this.token, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kNavyDark, width: 2),
          boxShadow: const [
            BoxShadow(
              color: _kNavyDark,
              offset: Offset(4, 4),
              blurRadius: 0,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // TOP BAR BADGE & MINI APP ICON
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                // PASTEL CATEGORY BADGE WITH THIN BLACK OUTLINE
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: token.pastelBg,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kNavyDark, width: 1.2),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(token.icon, size: 14, color: token.textIconColor),
                      const SizedBox(width: 4),
                      Text(
                        token.category,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: token.textIconColor),
                      ),
                    ],
                  ),
                ),
                // MINI APP BADGE POJOK CARD
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: _kCreamBg,
                    shape: BoxShape.circle,
                    border: Border.all(color: _kNavyDark, width: 1.2),
                  ),
                  child: const Icon(Icons.arrow_forward_rounded, color: _kNavyDark, size: 14),
                ),
              ],
            ),

            // APP NAME & DESCRIPTION
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  token.name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: _kNavyDark),
                ),
                const SizedBox(height: 4),
                Text(
                  token.desc,
                  style: const TextStyle(fontSize: 12, color: Colors.black87, height: 1.3, fontWeight: FontWeight.w500),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),

            // RETRO CTA BUTTON (ROUNDED-FULL NAVY/MUSTARD)
            SizedBox(
              width: double.infinity,
              height: 38,
              child: ElevatedButton.icon(
                onPressed: onTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: token.pastelBg,
                  foregroundColor: token.textIconColor,
                  elevation: 0,
                  side: const BorderSide(color: _kNavyDark, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                icon: const Icon(Icons.play_arrow_rounded, size: 16),
                label: Text('Buka Modul ${token.name}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}