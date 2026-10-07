import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/quizizz_service.dart';
import '../quizizz/quizizz_screen.dart';
import '../research/research_class_screen.dart';
import '../login_screen.dart';
import '../complete_profile_screen.dart';
import '../../widgets/doodle_pattern_background.dart';
import '../../utils/qr_scanner_helper.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);
const Color _kPastelAccent = Color(0xFF6EA2B3);
const Color _kAccentText = Color(0xFF0A4174);

// ============================================================================
// FITUR "MANAJEMEN KELAS" — DASHBOARD KELAS
// ============================================================================
// Halaman ini ditampilkan SETELAH login, SEBELUM masuk ke modul Quizizz.
// - Dosen: bisa membuat banyak kelas (nama + mata kuliah wajib diisi),
//   setiap kelas otomatis dapat token unik untuk dibagikan ke mahasiswa.
// - Mahasiswa: WAJIB join kelas (masukkan token) sebelum bisa mengakses
//   konten apapun. Keanggotaan tersimpan permanen di backend, jadi kelas
//   yang sudah diikuti otomatis tampil lagi setiap login berikutnya tanpa
//   perlu input token ulang. Mahasiswa bisa join banyak kelas berbeda.
// ============================================================================
class ClassDashboardScreen extends StatefulWidget {
  const ClassDashboardScreen({super.key});

  @override
  State<ClassDashboardScreen> createState() => _ClassDashboardScreenState();
}

class _ClassDashboardScreenState extends State<ClassDashboardScreen> {
  bool _loading = true;
  List<Map<String, dynamic>> _classes = [];

  @override
  void initState() {
    super.initState();
    _loadClasses();
  }

  bool get _isDosen {
    final user = context.read<AuthProvider>().user;
    return user?['role'] == 'dosen';
  }

  Future<void> _loadClasses() async {
    setState(() => _loading = true);
    final list = _isDosen
        ? await QuizizzService.getMyClasses()
        : await QuizizzService.getJoinedClasses();
    if (!mounted) return;
    setState(() {
      _classes = list;
      _loading = false;
    });
  }

  void _openClass(Map<String, dynamic> cls) {
    final classType = cls['class_type']?.toString();
    if (classType == 'riset') {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ResearchClassScreen(
            classId: cls['id']?.toString() ?? '',
            className: cls['class_name']?.toString() ?? '',
            subject: cls['subject']?.toString(),
            dosenId: cls['dosen_id']?.toString(),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => QuizizzScreen(
            classId: cls['id']?.toString(),
            className: cls['class_name']?.toString(),
          ),
        ),
      );
    }
  }

  Future<void> _showCreateClassDialog() async {
    final nameCtrl = TextEditingController();
    final subjectCtrl = TextEditingController();
    String selectedClassType = 'mata_kuliah'; // 'mata_kuliah' atau 'riset'

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1.5)),
                child: const Icon(Icons.school_rounded, color: _kNavyDark, size: 22),
              ),
              const SizedBox(width: 12),
              const Text('🏫 Buat Kelas Baru', style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Pilih Jenis Kelas:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                  const SizedBox(height: 8),

                  // PILIHAN 1: KELAS MATA KULIAH (EKSISTING)
                  InkWell(
                    onTap: () => setDialogState(() => selectedClassType = 'mata_kuliah'),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: selectedClassType == 'mata_kuliah' ? _kCreamBg.withOpacity(0.5) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selectedClassType == 'mata_kuliah' ? _kNavyDark : Colors.black12,
                          width: selectedClassType == 'mata_kuliah' ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Radio<String>(
                            value: 'mata_kuliah',
                            groupValue: selectedClassType,
                            activeColor: _kNavyDark,
                            onChanged: (val) => setDialogState(() => selectedClassType = val!),
                          ),
                          const SizedBox(width: 4),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('📘 Pilihan 1: Kelas Mata Kuliah (Eksisting)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark)),
                                SizedBox(height: 2),
                                Text('Dashboard kuis interaktif, presentasi materi, flashcard, presensi QR, dan rekap nilai.', style: TextStyle(fontSize: 11, color: Colors.black54)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // PILIHAN 2: KELAS RISET / CAPSTONE
                  InkWell(
                    onTap: () => setDialogState(() => selectedClassType = 'riset'),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: selectedClassType == 'riset' ? const Color(0xFFE0E7FF) : const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: selectedClassType == 'riset' ? const Color(0xFF4338CA) : Colors.black12,
                          width: selectedClassType == 'riset' ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          Radio<String>(
                            value: 'riset',
                            groupValue: selectedClassType,
                            activeColor: const Color(0xFF4338CA),
                            onChanged: (val) => setDialogState(() => selectedClassType = val!),
                          ),
                          const SizedBox(width: 4),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('🔬 Pilihan 2: Kelas Riset / Capstone', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF312E81))),
                                SizedBox(height: 2),
                                Text('Grup capstone tugas akhir, QR join grup, ruang diskusi grup & japri, approval dokumen & TTD digital.', style: TextStyle(fontSize: 11, color: Colors.black54)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),

                  const Text('Nama Kelas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: nameCtrl,
                    decoration: InputDecoration(
                      hintText: selectedClassType == 'riset' ? 'Contoh: Capstone Riset Semester Ganjil' : 'Contoh: Kelas A - Pemrograman Web',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),

                  const Text('Nama Mata Kuliah / Bidang Riset', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: subjectCtrl,
                    decoration: InputDecoration(
                      hintText: selectedClassType == 'riset' ? 'Contoh: Tugas Akhir / Riset AI & Keamanan' : 'Contoh: Basis Data',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold))),
            ElevatedButton(
              onPressed: () async {
                if (nameCtrl.text.trim().isEmpty || subjectCtrl.text.trim().isEmpty) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Nama kelas dan mata kuliah wajib diisi')));
                  return;
                }
                final result = await QuizizzService.createClass(
                  className: nameCtrl.text.trim(),
                  subject: subjectCtrl.text.trim(),
                  classType: selectedClassType,
                );
                if (ctx.mounted) Navigator.pop(ctx, result != null);
                if (result != null && ctx.mounted) {
                  _showTokenDialog(result);
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('Buat Kelas', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    if (created == true) await _loadClasses();
  }

  void _showTokenDialog(Map<String, dynamic> cls) {
    final isRiset = cls['class_type'] == 'riset';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: Text(isRiset ? '✅ Kelas Riset Berhasil Dibuat' : '✅ Kelas Berhasil Dibuat', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${cls['class_name']} — ${cls['subject']}', style: const TextStyle(fontWeight: FontWeight.w600, color: _kNavyDark)),
            const SizedBox(height: 16),
            const Text('Bagikan token ini ke mahasiswa untuk join kelas:', style: TextStyle(fontSize: 12, color: Colors.black54)),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.5)),
              child: Center(
                child: Text(
                  cls['token'] ?? '',
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 28, color: _kNavyDark, letterSpacing: 4),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: cls['token'] ?? ''));
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Token disalin!')));
            },
            icon: const Icon(Icons.copy_rounded, size: 16, color: _kNavyDark),
            label: const Text('Salin Token', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('Tutup', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  String _cleanScannedToken(String raw) {
    var t = raw.trim();
    if (t.contains('token=')) {
      final match = RegExp(r'token=([^&]+)').firstMatch(t);
      if (match != null) return match.group(1)?.trim() ?? t;
    }
    if (t.contains('join=')) {
      final match = RegExp(r'join=([^&]+)').firstMatch(t);
      if (match != null) return match.group(1)?.trim() ?? t;
    }
    if (t.contains('/join/')) {
      final parts = t.split('/join/');
      if (parts.length > 1 && parts.last.isNotEmpty) {
        return parts.last.split('?').first.split('#').first.trim();
      }
    }
    return t;
  }

  Future<void> _showJoinClassDialog() async {
    final tokenCtrl = TextEditingController();
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final nimCtrl = TextEditingController(text: auth.user?['nim']?.toString() ?? '');
    final nameCtrl = TextEditingController(text: auth.user?['full_name']?.toString() ?? auth.user?['name']?.toString() ?? '');
    String? errorText;

    final joined = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1.5)),
                child: const Icon(Icons.key_rounded, color: _kNavyDark, size: 20),
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text('🔑 Join Kelas / Grup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark)),
              ),
            ],
          ),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // TOMBOL SCAN QR CODE DARI KAMERA
                  ElevatedButton.icon(
                    onPressed: () async {
                      final scanned = await QrScannerHelper.scanQr();
                      if (scanned != null && scanned.trim().isNotEmpty) {
                        final tokenClean = _cleanScannedToken(scanned);
                        setDialogState(() {
                          tokenCtrl.text = tokenClean;
                          errorText = null;
                        });
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text('✅ QR Code berhasil dipindai dari kamera: $tokenClean'),
                              backgroundColor: const Color(0xFF059669),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.camera_alt_rounded, size: 20),
                    label: const Text('📷 Scan QR Code (Kamera Langsung)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEFF6FF),
                      foregroundColor: const Color(0xFF1D4ED8),
                      elevation: 0,
                      side: const BorderSide(color: Color(0xFF93C5FD), width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // TOMBOL LOAD IMAGE QR DARI FILE
                  ElevatedButton.icon(
                    onPressed: () async {
                      final scanned = await QrScannerHelper.scanQrFromFile();
                      if (scanned != null && scanned.trim().isNotEmpty) {
                        final tokenClean = _cleanScannedToken(scanned);
                        setDialogState(() {
                          tokenCtrl.text = tokenClean;
                          errorText = null;
                        });
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                              content: Text('✅ QR Code berhasil dimuat dari file: $tokenClean'),
                              backgroundColor: const Color(0xFF059669),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        }
                      }
                    },
                    icon: const Icon(Icons.drive_folder_upload_rounded, size: 20),
                    label: const Text('📁 Load Gambar QR dari File', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFF0FDF4),
                      foregroundColor: const Color(0xFF15803D),
                      elevation: 0,
                      side: const BorderSide(color: Color(0xFF86EFAC), width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    ),
                  ),
                  const SizedBox(height: 14),

                  const Row(
                    children: [
                      Expanded(child: Divider()),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 10),
                        child: Text('ATAU KETIK KODE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black45)),
                      ),
                      Expanded(child: Divider()),
                    ],
                  ),
                  const SizedBox(height: 12),

                  const Text('Masukkan Token Kelas atau Kode Grup Riset dari dosen:', style: TextStyle(fontSize: 12, color: Colors.black54)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: tokenCtrl,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, letterSpacing: 2, color: _kNavyDark),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: 'Contoh: ABC123 atau R-G1-XXXX',
                      errorText: errorText,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                    ),
                  ),
                  const SizedBox(height: 14),

                  if (auth.user?['nim'] == null || auth.user!['nim'].toString().isEmpty) ...[
                    const Text('NIM Anda', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: nimCtrl,
                      decoration: InputDecoration(
                        hintText: 'Masukkan NIM Anda...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 10),
                    const Text('Nama Lengkap Anda', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(height: 4),
                    TextField(
                      controller: nameCtrl,
                      decoration: InputDecoration(
                        hintText: 'Masukkan Nama Lengkap Anda...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold))),
            ElevatedButton(
              onPressed: () async {
                final token = tokenCtrl.text.trim();
                if (token.isEmpty) {
                  setDialogState(() => errorText = 'Kode kelas atau grup wajib diisi');
                  return;
                }
                try {
                  final result = await QuizizzService.joinClass(
                    token,
                    studentName: nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : null,
                    nim: nimCtrl.text.trim().isNotEmpty ? nimCtrl.text.trim() : null,
                  );
                  if (result != null && ctx.mounted) {
                    Navigator.pop(ctx, true);
                    final msg = result['message'] ?? 'Berhasil bergabung ke kelas';
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('✅ $msg'), backgroundColor: const Color(0xFF059669)),
                    );
                  }
                } catch (e) {
                  setDialogState(() => errorText = 'Kode tidak ditemukan. Periksa kembali token/QR dari dosen Anda.');
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('Join Kelas', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
    if (joined == true) await _loadClasses();
  }

  // Fitur "Hapus Kelas": dosen menghapus kelas miliknya secara permanen
  // (beserta seluruh kuis/PR/presentasi/flashcard di dalamnya), mahasiswa
  // hanya "keluar" dari kelas (kelasnya sendiri tidak terhapus).
  Future<void> _confirmDeleteOrLeaveClass(Map<String, dynamic> cls) async {
    final classId = cls['id']?.toString() ?? '';
    final className = cls['class_name']?.toString() ?? '';
    final isDosen = _isDosen;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: Text(isDosen ? '🗑️ Hapus Kelas?' : '🚪 Keluar dari Kelas?', style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark)),
        content: Text(
          isDosen
              ? 'Kelas "$className" beserta SEMUA kuis, PR, presentasi, dan flashcard di dalamnya akan dihapus PERMANEN. Mahasiswa yang tergabung juga akan kehilangan akses. Tindakan ini tidak bisa dibatalkan.'
              : 'Anda akan keluar dari kelas "$className". Anda perlu memasukkan token lagi kalau ingin bergabung ke kelas ini di kemudian hari.',
          style: const TextStyle(color: Colors.black54),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: Text(isDosen ? 'Ya, Hapus Permanen' : 'Ya, Keluar', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final success = isDosen ? await QuizizzService.deleteClass(classId) : await QuizizzService.leaveClass(classId);
    if (!mounted) return;
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isDosen ? '✅ Kelas berhasil dihapus' : '✅ Berhasil keluar dari kelas'), backgroundColor: const Color(0xFF059669)),
      );
      await _loadClasses();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('❌ Gagal memproses permintaan. Coba lagi.'), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final isDosen = _isDosen;
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;

    return Scaffold(
      backgroundColor: _kCreamBg,
      body: Stack(
        children: [
          // FITUR "Pattern Dekoratif Doodle Edukasi"
          const Positioned.fill(child: DoodlePatternBackground(color: _kNavyDark)),
          SafeArea(
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? 12 : 20,
                vertical: isMobile ? 12 : 20,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // TOP BAR (RESPONSIVE)
                      Container(
                        padding: EdgeInsets.all(isMobile ? 12 : 16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(color: _kNavyDark, width: 2),
                          boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
                        ),
                        child: isMobile
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: _kMustardYellow,
                                          borderRadius: BorderRadius.circular(12),
                                          border: Border.all(color: _kNavyDark, width: 1.5),
                                        ),
                                        child: const Icon(Icons.groups_rounded, color: _kNavyDark, size: 20),
                                      ),
                                      const SizedBox(width: 10),
                                      const Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text('Classly', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
                                            Text(
                                              'Ide Cerdas, Kelas Terkoneksi',
                                              style: TextStyle(fontSize: 10, color: Colors.black54, fontWeight: FontWeight.w600),
                                            ),
                                          ],
                                        ),
                                      ),
                                      IconButton(
                                        icon: const Icon(Icons.badge_outlined, color: _kNavyDark, size: 20),
                                        tooltip: 'Lengkapi Profil',
                                        padding: const EdgeInsets.all(6),
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CompleteProfileScreen()));
                                        },
                                      ),
                                      const SizedBox(width: 6),
                                      IconButton(
                                        icon: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
                                        tooltip: 'Logout',
                                        padding: const EdgeInsets.all(6),
                                        constraints: const BoxConstraints(),
                                        onPressed: () async {
                                          await context.read<AuthProvider>().logout();
                                          if (mounted) {
                                            Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _kCreamBg.withOpacity(0.35),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: _kNavyDark.withOpacity(0.15), width: 1),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(isDosen ? Icons.person_outline_rounded : Icons.school_outlined, size: 14, color: _kNavyDark),
                                        const SizedBox(width: 6),
                                        Expanded(
                                          child: Text(
                                            '${user?['full_name'] ?? user?['name'] ?? ''} • ${isDosen ? 'Dosen' : 'Mahasiswa'}',
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              )
                            : Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.all(8),
                                    decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(14), border: Border.all(color: _kNavyDark, width: 1.5)),
                                    child: const Icon(Icons.groups_rounded, color: _kNavyDark, size: 20),
                                  ),
                                  const SizedBox(width: 10),
                                  const Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Classly', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark)),
                                        Text(
                                          'Ide Cerdas, Kelas Terkoneksi',
                                          style: TextStyle(fontSize: 10, color: Colors.black54, fontWeight: FontWeight.w600),
                                        ),
                                      ],
                                    ),
                                  ),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: _kCreamBg.withOpacity(0.35),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: _kNavyDark.withOpacity(0.15), width: 1),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(isDosen ? Icons.person_outline_rounded : Icons.school_outlined, size: 14, color: _kNavyDark),
                                        const SizedBox(width: 6),
                                        ConstrainedBox(
                                          constraints: const BoxConstraints(maxWidth: 160),
                                          child: Text(
                                            user?['full_name'] ?? user?['name'] ?? '',
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11, color: _kNavyDark),
                                            overflow: TextOverflow.ellipsis,
                                            maxLines: 1,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(Icons.badge_outlined, color: _kNavyDark, size: 20),
                                    tooltip: 'Lengkapi Profil',
                                    padding: const EdgeInsets.all(6),
                                    constraints: const BoxConstraints(),
                                    onPressed: () {
                                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CompleteProfileScreen()));
                                    },
                                  ),
                                  const SizedBox(width: 4),
                                  IconButton(
                                    icon: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 20),
                                    tooltip: 'Logout',
                                    padding: const EdgeInsets.all(6),
                                    constraints: const BoxConstraints(),
                                    onPressed: () async {
                                      await context.read<AuthProvider>().logout();
                                      if (mounted) {
                                        Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginScreen()));
                                      }
                                    },
                                  ),
                                ],
                              ),
                      ),
                      const SizedBox(height: 20),

                      // SECTION TITLE + CTA (RESPONSIVE)
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          Text(
                            isDosen ? 'Kelas Saya (${_classes.length})' : 'Kelas yang Diikuti (${_classes.length})',
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: _kNavyDark),
                          ),
                          ElevatedButton.icon(
                            onPressed: isDosen ? _showCreateClassDialog : _showJoinClassDialog,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _kNavyDark,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30), side: const BorderSide(color: _kNavyDark, width: 1.5)),
                              elevation: 0,
                            ),
                            icon: Icon(isDosen ? Icons.add_circle_rounded : Icons.key_rounded, color: _kMustardYellow, size: 18),
                            label: Text(isDosen ? 'Buat Kelas Baru' : 'Join Kelas', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // LIST KELAS
                      if (_loading)
                        const Center(
                          child: Padding(
                            padding: EdgeInsets.symmetric(vertical: 40),
                            child: CircularProgressIndicator(color: _kNavyDark),
                          ),
                        )
                      else if (_classes.isEmpty)
                        _buildEmptyState(isDosen)
                      else
                        LayoutBuilder(
                          builder: (ctx, constraints) {
                            final isSmall = constraints.maxWidth < 650;
                            return Wrap(
                              spacing: 16,
                              runSpacing: 16,
                              children: _classes.map((cls) => _ClassCard(
                                    cls: cls,
                                    isDosen: isDosen,
                                    isMobile: isSmall,
                                    onTap: () => _openClass(cls),
                                    onShowToken: isDosen ? () => _showTokenDialog(cls) : null,
                                    onDelete: () => _confirmDeleteOrLeaveClass(cls),
                                  )).toList(),
                            );
                          },
                        ),
                      const SizedBox(height: 48), // Padding bawah agar mudah di-scroll di mobile
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isDosen) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(isDosen ? Icons.school_outlined : Icons.groups_outlined, size: 64, color: _kNavyDark.withOpacity(0.4)),
          const SizedBox(height: 16),
          Text(
            isDosen ? 'Anda belum membuat kelas apapun.' : 'Anda belum bergabung ke kelas manapun.',
            style: const TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark),
          ),
          const SizedBox(height: 6),
          Text(
            isDosen ? 'Tekan "Buat Kelas Baru" untuk memulai.' : 'Minta token kelas dari dosen Anda, lalu tekan "Join Kelas".',
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ],
      ),
    );
  }
}

// ============================================================================
// KARTU KELAS (RESPONSIVE)
// ============================================================================
class _ClassCard extends StatelessWidget {
  final Map<String, dynamic> cls;
  final bool isDosen;
  final bool isMobile;
  final VoidCallback onTap;
  final VoidCallback? onShowToken;
  final VoidCallback? onDelete;

  const _ClassCard({
    required this.cls,
    required this.isDosen,
    this.isMobile = false,
    required this.onTap,
    this.onShowToken,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final memberCount = cls['member_count'] ?? 0;
    final quizCount = cls['quiz_count'] ?? 0;
    final isResearch = (cls['class_type'] ?? 'mata_kuliah') == 'riset';
    final groupCount = cls['group_count'] ?? 0;
    final myGroupName = cls['my_group_name']?.toString();

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        width: isMobile ? double.infinity : 320,
        height: 220,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _kNavyDark, width: 2),
          boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: isResearch ? const Color(0xFFEDE9FE) : const Color(0xFFE0F2FE),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: isResearch ? const Color(0xFF7C3AED) : const Color(0xFF0284C7), width: 1.2),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(isResearch ? Icons.science_rounded : Icons.menu_book_rounded, size: 12, color: isResearch ? const Color(0xFF7C3AED) : const Color(0xFF0284C7)),
                          const SizedBox(width: 4),
                          Text(
                            isResearch ? 'RISET' : 'KULIAH',
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: isResearch ? const Color(0xFF7C3AED) : const Color(0xFF0284C7)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: _kPastelAccent, borderRadius: BorderRadius.circular(12), border: Border.all(color: _kNavyDark, width: 1)),
                        child: Text(cls['subject'] ?? '', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: _kAccentText), overflow: TextOverflow.ellipsis),
                      ),
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isDosen && onShowToken != null)
                      InkWell(
                        onTap: onShowToken,
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(color: _kCreamBg, shape: BoxShape.circle, border: Border.all(color: _kNavyDark, width: 1.2)),
                          child: const Icon(Icons.vpn_key_rounded, color: _kNavyDark, size: 14),
                        ),
                      ),
                    if (onDelete != null) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: onDelete,
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(color: const Color(0xFFFEE2E2), shape: BoxShape.circle, border: Border.all(color: Colors.redAccent, width: 1.2)),
                          child: Icon(isDosen ? Icons.delete_outline_rounded : Icons.logout_rounded, color: Colors.redAccent, size: 14),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            Text(
              cls['class_name'] ?? '',
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: _kNavyDark),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (isResearch) ...[
              Row(
                children: [
                  const Icon(Icons.hub_rounded, size: 14, color: Colors.black54),
                  const SizedBox(width: 4),
                  if (isDosen)
                    Text('$groupCount Grup Capstone', style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600))
                  else
                    Text(myGroupName != null ? 'Grup: $myGroupName' : 'Belum masuk grup', style: TextStyle(fontSize: 11, color: myGroupName != null ? const Color(0xFF7C3AED) : Colors.black54, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  const Icon(Icons.people_alt_rounded, size: 14, color: Colors.black54),
                  const SizedBox(width: 4),
                  Text('$memberCount Mahasiswa', style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
                ],
              ),
            ] else ...[
              Row(
                children: [
                  const Icon(Icons.quiz_rounded, size: 14, color: Colors.black54),
                  const SizedBox(width: 4),
                  Text('$quizCount Kuis/PR', style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
                  if (isDosen) ...[
                    const SizedBox(width: 12),
                    const Icon(Icons.people_alt_rounded, size: 14, color: Colors.black54),
                    const SizedBox(width: 4),
                    Text('$memberCount Mahasiswa', style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
                  ],
                ],
              ),
            ],
            SizedBox(
              width: double.infinity,
              height: 38,
              child: ElevatedButton.icon(
                onPressed: onTap,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isResearch ? const Color(0xFF8B5CF6) : _kPastelAccent,
                  foregroundColor: isResearch ? Colors.white : _kAccentText,
                  elevation: 0,
                  side: const BorderSide(color: _kNavyDark, width: 1.5),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                ),
                icon: const Icon(Icons.arrow_forward_rounded, size: 16),
                label: Text(isResearch ? 'Buka Ruang Riset' : 'Buka Kelas', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}