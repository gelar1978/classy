import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../services/quizizz_service.dart';
import '../../services/socket_service.dart';
import '../../utils/export_helper.dart';
import '../../utils/qr_scanner_helper.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);
const Color _kPastelAccent = Color(0xFF6EA2B3);

// ============================================================================
// DOSEN: TAB PRESENSI KELAS (QR CODE PEKAN KE-SEKIAN)
// ============================================================================
class AttendanceDosenTabView extends StatefulWidget {
  final String? classId;
  final String? className;

  const AttendanceDosenTabView({
    super.key,
    this.classId,
    this.className,
  });

  @override
  State<AttendanceDosenTabView> createState() => _AttendanceDosenTabViewState();
}

class _AttendanceDosenTabViewState extends State<AttendanceDosenTabView> {
  bool _loading = true;
  List<Map<String, dynamic>> _sessions = [];
  Map<String, dynamic>? _activeSessionDetail;
  String? _selectedSessionId;
  String _statusFilter = 'all'; // 'all', 'hadir', 'belum_hadir'
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadSessions();
    _setupSocketListener();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_selectedSessionId != null && mounted) {
        _loadSessionDetail(_selectedSessionId!, showLoading: false);
      }
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _setupSocketListener() {
    SocketService.on('attendance_updated', (data) {
      if (!mounted) return;
      if (_selectedSessionId != null && data != null) {
        final incomingSessId = data['session_id']?.toString();
        if (incomingSessId == _selectedSessionId) {
          _loadSessionDetail(_selectedSessionId!, showLoading: false);
        }
      }
    });
  }

  String get _effectiveClassId =>
      widget.classId ?? QuizizzService.currentClassId ?? '';

  Future<void> _loadSessions() async {
    final cId = _effectiveClassId;
    if (cId.isEmpty) {
      setState(() => _loading = false);
      return;
    }

    setState(() => _loading = true);
    final list = await QuizizzService.getAttendanceSessions(cId);
    if (!mounted) return;

    setState(() {
      _sessions = list;
      _loading = false;
    });

    // Auto-select open session or latest session
    if (_sessions.isNotEmpty) {
      final openSess = _sessions.firstWhere(
        (s) => s['status'] == 'open',
        orElse: () => _sessions.first,
      );
      _selectSession(openSess['id']?.toString());
    } else {
      setState(() => _activeSessionDetail = null);
    }
  }

  Future<void> _selectSession(String? sessionId) async {
    if (sessionId == null) return;
    setState(() => _selectedSessionId = sessionId);
    await _loadSessionDetail(sessionId, showLoading: true);
  }

  Future<void> _loadSessionDetail(String sessionId, {bool showLoading = true}) async {
    if (showLoading) {
      setState(() => _loading = true);
    }
    final detail = await QuizizzService.getAttendanceDetail(sessionId);
    if (!mounted) return;
    setState(() {
      _activeSessionDetail = detail;
      if (showLoading) _loading = false;
    });
  }

  Future<void> _showOpenSessionDialog() async {
    final weekCtrl = TextEditingController(text: '${_sessions.length + 1}');
    final titleCtrl = TextEditingController(
      text: 'Presensi Pekan ${_sessions.length + 1} - ${widget.className ?? "Stegano"}',
    );

    final opened = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _kNavyDark, width: 2),
        ),
        title: const Text(
          '📅 Buka Presensi Pekan Baru',
          style: TextStyle(fontWeight: FontWeight.bold, color: _kNavyDark),
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Pekan Ke-', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
              const SizedBox(height: 6),
              TextField(
                controller: weekCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: '1, 2, 3...',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Judul Sesi Presensi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
              const SizedBox(height: 6),
              TextField(
                controller: titleCtrl,
                decoration: InputDecoration(
                  hintText: 'Contoh: Presensi Pekan 1 - Citra Digital',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: _kNavyDark)),
          ),
          ElevatedButton(
            onPressed: () async {
              final weekNum = int.tryParse(weekCtrl.text.trim()) ?? 1;
              final res = await QuizizzService.openAttendanceSession(
                classId: _effectiveClassId,
                weekNumber: weekNum,
                title: titleCtrl.text.trim(),
              );
              if (ctx.mounted) Navigator.pop(ctx, res != null);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Buka & Tampilkan QR'),
          ),
        ],
      ),
    );

    if (opened == true) {
      await _loadSessions();
    }
  }

  Future<void> _closeSession(String sessionId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tutup Sesi Presensi?'),
        content: const Text('Mahasiswa tidak akan bisa lagi melakukan presensi setelah sesi ini ditutup.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: const Text('Tutup Sesi'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await QuizizzService.closeAttendanceSession(sessionId);
      await _loadSessions();
    }
  }

  void _showFullscreenQr(Map<String, dynamic> session) {
    final sessionCode = session['session_code'] ?? '';
    final title = session['title'] ?? 'Presensi Kelas';
    final qrData = session['qr_data'] ?? sessionCode;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: const BorderSide(color: _kNavyDark, width: 3),
        ),
        child: Container(
          width: 500,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: _kNavyDark),
              ),
              const SizedBox(height: 8),
              const Text(
                'Scan QR Code atau masukkan Kode Presensi di portal Classly:',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _kNavyDark, width: 2.5),
                  boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(6, 6), blurRadius: 0)],
                ),
                child: QrImageView(
                  data: qrData,
                  version: QrVersions.auto,
                  size: 260,
                  backgroundColor: Colors.white,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _kNavyDark),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: _kNavyDark),
                ),
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(
                  color: _kMustardYellow,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _kNavyDark, width: 2),
                ),
                child: Text(
                  sessionCode,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 32, letterSpacing: 6, color: _kNavyDark),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kNavyDark,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                ),
                child: const Text('Tutup Layar Penuh', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _exportAttendance(Map<String, dynamic> session, List<Map<String, dynamic>> attendees) {
    final title = session['title'] ?? 'Presensi_Kelas';
    ExportHelper.exportAttendanceToExcel(
      sessionTitle: title,
      attendees: attendees,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('✅ File Presensi (.xlsx) berhasil diunduh!'), backgroundColor: Color(0xFF059669)),
    );
  }

  Future<void> _showEditStatusDialog(Map<String, dynamic> attendee) async {
    String currentStatus = (attendee['status'] ?? 'belum_hadir').toString();
    final notesCtrl = TextEditingController(text: attendee['notes'] ?? '');

    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlgState) => AlertDialog(
          backgroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: _kNavyDark, width: 2),
          ),
          title: Text(
            'Ubah Status: ${attendee['student_name']}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
          ),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('NIM: ${attendee['nim']}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const SizedBox(height: 16),
                const Text('Status Kehadiran', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  value: currentStatus,
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'hadir', child: Text('🟢 HADIR')),
                    DropdownMenuItem(value: 'belum_hadir', child: Text('🔴 BELUM HADIR')),
                    DropdownMenuItem(value: 'sakit', child: Text('🟡 SAKIT')),
                    DropdownMenuItem(value: 'izin', child: Text('🔵 IZIN')),
                    DropdownMenuItem(value: 'alfa', child: Text('🟠 ALFA')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDlgState(() => currentStatus = val);
                  },
                ),
                const SizedBox(height: 16),
                const Text('Catatan / Keterangan', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                const SizedBox(height: 6),
                TextField(
                  controller: notesCtrl,
                  decoration: InputDecoration(
                    hintText: 'Surat dokter, izin lomba, dll.',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal')),
            ElevatedButton(
              onPressed: () async {
                final recId = attendee['record_id']?.toString();
                if (recId != null && recId.isNotEmpty) {
                  final ok = await QuizizzService.updateAttendanceStatus(
                    recordId: recId,
                    status: currentStatus,
                    notes: notesCtrl.text.trim().isNotEmpty ? notesCtrl.text.trim() : null,
                  );
                  if (ctx.mounted) Navigator.pop(ctx, ok);
                } else {
                  // If record didn't exist yet, we can submit directly via record update API
                  if (ctx.mounted) Navigator.pop(ctx, true);
                }
              },
              style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white),
              child: const Text('Simpan'),
            ),
          ],
        ),
      ),
    );

    if (updated == true && _selectedSessionId != null) {
      await _loadSessionDetail(_selectedSessionId!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _sessions.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    }

    final session = _activeSessionDetail?['session'] as Map<String, dynamic>?;
    final attendees = (_activeSessionDetail?['attendees'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final totalHadir = _activeSessionDetail?['total_hadir'] ?? 0;
    final totalMembers = _activeSessionDetail?['total_members'] ?? attendees.length;
    final isOpen = session?['status'] == 'open';

    final filteredAttendees = attendees.where((a) {
      if (_statusFilter == 'hadir') return a['status'] == 'hadir';
      if (_statusFilter == 'belum_hadir') return a['status'] == 'belum_hadir';
      return true;
    }).toList();

    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          // TOP ACTION BAR
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.qr_code_scanner_rounded, size: 24, color: _kNavyDark),
                  const SizedBox(width: 8),
                  Text(
                    'Presensi Kelas (${_sessions.length} Sesi Pekan)',
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: _showOpenSessionDialog,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kNavyDark,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
                icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
                label: const Text('Buka Presensi Pekan...', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // SESSIONS TABS / CHIPS SELECTOR
          if (_sessions.isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _sessions.map((s) {
                  final sId = s['id']?.toString();
                  final isSelected = sId == _selectedSessionId;
                  final isSessOpen = s['status'] == 'open';
                  final week = s['week_number'] ?? 1;

                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isSessOpen) ...[
                            Container(width: 8, height: 8, decoration: const BoxDecoration(color: Color(0xFF059669), shape: BoxShape.circle)),
                            const SizedBox(width: 6),
                          ],
                          Text(
                            'Pekan $week ${isSessOpen ? "(LIVE)" : ""}',
                            style: TextStyle(
                              fontWeight: isSelected ? FontWeight.w900 : FontWeight.bold,
                              color: isSelected ? _kNavyDark : Colors.black54,
                            ),
                          ),
                        ],
                      ),
                      selected: isSelected,
                      selectedColor: _kMustardYellow,
                      backgroundColor: Colors.white,
                      side: BorderSide(color: isSelected ? _kNavyDark : Colors.black26, width: isSelected ? 1.5 : 1),
                      onSelected: (_) => _selectSession(sId),
                    ),
                  );
                }).toList(),
              ),
            ),
          const SizedBox(height: 20),

          // ACTIVE SESSION QR CARD
          if (session != null) ...[
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _kNavyDark, width: 2),
                boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // QR CODE DISPLAY
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: _kCreamBg.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: _kNavyDark, width: 1.5),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        QrImageView(
                          data: session['qr_data'] ?? session['session_code'] ?? '',
                          version: QrVersions.auto,
                          size: 150,
                          backgroundColor: Colors.white,
                          eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: _kNavyDark),
                          dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: _kNavyDark),
                        ),
                        const SizedBox(height: 8),
                        TextButton.icon(
                          onPressed: () => _showFullscreenQr(session),
                          icon: const Icon(Icons.fullscreen_rounded, size: 16, color: _kNavyDark),
                          label: const Text('Perbesar QR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kNavyDark)),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),

                  // SESSION DETAILS & COUNTER
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: isOpen ? const Color(0xFFD1FAE5) : Colors.grey.shade200,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: isOpen ? const Color(0xFF059669) : Colors.black26),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 8,
                                    height: 8,
                                    decoration: BoxDecoration(
                                      color: isOpen ? const Color(0xFF059669) : Colors.grey,
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    isOpen ? 'SESI DIBUKA (LIVE)' : 'SESI DITUTUP',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 11,
                                      color: isOpen ? const Color(0xFF065F46) : Colors.black54,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              'Pekan ${session['week_number']}',
                              style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _kNavyDark),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Text(
                          session['title'] ?? 'Presensi Kelas',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 20, color: _kNavyDark),
                        ),
                        const SizedBox(height: 12),

                        // KODE PRESENSI BIG
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                              decoration: BoxDecoration(
                                color: _kMustardYellow,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: _kNavyDark, width: 1.5),
                              ),
                              child: Text(
                                session['session_code'] ?? '-',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 22,
                                  letterSpacing: 4,
                                  color: _kNavyDark,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            IconButton(
                              icon: const Icon(Icons.copy_rounded, color: _kNavyDark, size: 20),
                              tooltip: 'Salin Kode Presensi',
                              onPressed: () {
                                Clipboard.setData(ClipboardData(text: session['session_code'] ?? ''));
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kode presensi disalin!')));
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // ATTENDEE COUNTER
                        Row(
                          children: [
                            Text(
                              '🟢 $totalHadir / $totalMembers Mahasiswa Hadir',
                              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: _kNavyDark),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '(${totalMembers > 0 ? ((totalHadir / totalMembers) * 100).toStringAsFixed(0) : 0}%)',
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.black54),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // ACTION BUTTONS
                        Row(
                          children: [
                            if (isOpen) ...[
                              ElevatedButton.icon(
                                onPressed: () => _closeSession(session['id']),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                ),
                                icon: const Icon(Icons.lock_outline_rounded, size: 16),
                                label: const Text('Tutup Sesi Presensi', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                              const SizedBox(width: 10),
                            ],
                            ElevatedButton.icon(
                              onPressed: () => _exportAttendance(session, attendees),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF059669),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                              icon: const Icon(Icons.table_chart_rounded, size: 16),
                              label: const Text('Unduh Rekap (.xlsx)', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // FILTER & ATTENDEES TABLE
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Daftar Kehadiran Mahasiswa (${filteredAttendees.length})',
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                ),
                Row(
                  children: [
                    ChoiceChip(
                      label: Text('Semua ($totalMembers)'),
                      selected: _statusFilter == 'all',
                      onSelected: (_) => setState(() => _statusFilter = 'all'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text('Hadir ($totalHadir)'),
                      selected: _statusFilter == 'hadir',
                      onSelected: (_) => setState(() => _statusFilter = 'hadir'),
                    ),
                    const SizedBox(width: 6),
                    ChoiceChip(
                      label: Text('Belum Hadir (${totalMembers - totalHadir})'),
                      selected: _statusFilter == 'belum_hadir',
                      onSelected: (_) => setState(() => _statusFilter = 'belum_hadir'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),

            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _kNavyDark, width: 2),
                boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(18),
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(_kPastelAccent.withValues(alpha: 0.3)),
                  headingTextStyle: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13),
                  columns: const [
                    DataColumn(label: Text('No.')),
                    DataColumn(label: Text('NIM')),
                    DataColumn(label: Text('Nama Mahasiswa')),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Waktu Presensi')),
                    DataColumn(label: Text('Keterangan')),
                    DataColumn(label: Text('Aksi')),
                  ],
                  rows: filteredAttendees.map((a) {
                    final status = a['status']?.toString() ?? 'belum_hadir';
                    final isHadir = status == 'hadir';

                    return DataRow(
                      cells: [
                        DataCell(Text(a['no'].toString(), style: const TextStyle(fontWeight: FontWeight.bold))),
                        DataCell(Text(a['nim'] ?? '-', style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark))),
                        DataCell(Text(a['student_name'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold))),
                        DataCell(
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: isHadir ? const Color(0xFFD1FAE5) : const Color(0xFFFEE2E2),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: isHadir ? const Color(0xFF059669) : Colors.redAccent),
                            ),
                            child: Text(
                              isHadir ? '🟢 HADIR' : '🔴 BELUM HADIR',
                              style: TextStyle(
                                fontWeight: FontWeight.w900,
                                fontSize: 11,
                                color: isHadir ? const Color(0xFF065F46) : Colors.red.shade800,
                              ),
                            ),
                          ),
                        ),
                        DataCell(Text(
                          a['attended_at'] != null ? a['attended_at'].toString() : '-',
                          style: const TextStyle(fontSize: 12, color: Colors.black87),
                        )),
                        DataCell(Text(a['notes'] ?? '-', style: const TextStyle(fontSize: 12, color: Colors.black54))),
                        DataCell(
                          IconButton(
                            icon: const Icon(Icons.edit_outlined, size: 18, color: _kNavyDark),
                            tooltip: 'Ubah Status Presensi',
                            onPressed: () => _showEditStatusDialog(a),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ] else ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(36),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _kNavyDark, width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.event_busy_rounded, size: 54, color: Colors.black38),
                  const SizedBox(height: 14),
                  const Text(
                    'Belum Ada Sesi Presensi yang Dibuka',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
                  ),
                  const SizedBox(height: 6),
                  const Text('Tekan tombol "Buka Presensi Pekan..." di atas untuk membuat sesi presensi QR baru.', style: TextStyle(color: Colors.black54)),
                ],
              ),
            ),
          ],
          const SizedBox(height: 30),
        ],
      ),
      ),
    );
  }
}

// ============================================================================
// MAHASISWA: TAB SCAN QR & PRESENSI KELAS
// ============================================================================
class MahasiswaAttendanceSubTab extends StatefulWidget {
  final String? classId;
  final String? className;

  const MahasiswaAttendanceSubTab({
    super.key,
    this.classId,
    this.className,
  });

  @override
  State<MahasiswaAttendanceSubTab> createState() => _MahasiswaAttendanceSubTabState();
}

class _MahasiswaAttendanceSubTabState extends State<MahasiswaAttendanceSubTab> {
  bool _submitting = false;
  Map<String, dynamic>? _lastSuccessSession;
  List<Map<String, dynamic>> _myHistory = [];
  bool _loadingHistory = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _loadingHistory = true);
    final history = await QuizizzService.getStudentAttendanceHistory();
    if (!mounted) return;
    setState(() {
      _myHistory = history;
      _loadingHistory = false;
    });
  }

  Future<void> _processQrAttendance(String? rawScanned) async {
    if (rawScanned == null || rawScanned.trim().isEmpty) return;
    final scanned = rawScanned.trim();

    setState(() => _submitting = true);
    try {
      final res = await QuizizzService.submitAttendance(sessionCode: scanned, qrData: scanned);
      if (!mounted) return;
      setState(() {
        _lastSuccessSession = res['session'] as Map<String, dynamic>?;
        _submitting = false;
      });
      await _loadHistory();

      // Show success modal
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24),
              side: const BorderSide(color: Color(0xFF059669), width: 2.5),
            ),
            title: const Row(
              children: [
                Text('🎉 ', style: TextStyle(fontSize: 24)),
                Text('Presensi Berhasil!', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF065F46))),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  res['message'] ?? 'Anda telah tercatat HADIR.',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: _kNavyDark),
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD1FAE5),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF059669)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Sesi: ${_lastSuccessSession?['title'] ?? '-'}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF065F46))),
                      const SizedBox(height: 4),
                      Text('Kelas: ${_lastSuccessSession?['class_name'] ?? '-'}', style: const TextStyle(fontSize: 12, color: Color(0xFF065F46))),
                      const SizedBox(height: 4),
                      const Text('Status: ✅ HADIR (Tepat Waktu)', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 12, color: Color(0xFF065F46))),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF059669), foregroundColor: Colors.white),
                child: const Text('OK, Mantap!'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('❌ Gagal: $e'), backgroundColor: Colors.redAccent),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // FORM PRESENSI CARD
              Container(
                padding: const EdgeInsets.all(28),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: _kNavyDark, width: 2),
                  boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _kMustardYellow,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: _kNavyDark, width: 1.5),
                          ),
                          child: const Icon(Icons.qr_code_scanner_rounded, color: _kNavyDark, size: 24),
                        ),
                        const SizedBox(width: 14),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Presensi Kehadiran Kuliah',
                                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark),
                              ),
                              Text(
                                'Pindai QR Code Presensi dari Dosen Anda',
                                style: TextStyle(fontSize: 12, color: Colors.black54),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // OPSI 1: SCAN KAMERA
                    SizedBox(
                      height: 52,
                      child: ElevatedButton.icon(
                        onPressed: _submitting
                            ? null
                            : () async {
                                final scanned = await QrScannerHelper.scanQr();
                                if (scanned != null && scanned.trim().isNotEmpty) {
                                  _processQrAttendance(scanned);
                                }
                              },
                        icon: const Icon(Icons.camera_alt_rounded, size: 22),
                        label: Text(
                          _submitting ? 'Memproses Presensi...' : '📷 Scan QR Presensi (Kamera Langsung)',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kNavyDark,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // OPSI 2: UNGGAH FILE QR
                    SizedBox(
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _submitting
                            ? null
                            : () async {
                                final scanned = await QrScannerHelper.scanQrFromFile();
                                if (scanned != null && scanned.trim().isNotEmpty) {
                                  _processQrAttendance(scanned);
                                }
                              },
                        icon: const Icon(Icons.drive_folder_upload_rounded, size: 20),
                        label: const Text(
                          '📁 Unggah File / Gambar QR (Jika Kamera Bermasalah)',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFEFF6FF),
                          foregroundColor: const Color(0xFF1D4ED8),
                          elevation: 0,
                          side: const BorderSide(color: Color(0xFF93C5FD), width: 1.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // PETUNJUK
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.info_outline_rounded, size: 18, color: Color(0xFF64748B)),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Presensi hanya menggunakan pemindaian QR Code dari dosen. Apabila kamera browser bermasalah, Anda dapat mengunggah file screenshot / foto QR code secara langsung.',
                              style: TextStyle(fontSize: 11, color: Color(0xFF475569), height: 1.3),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              // RIWAYAT PRESENSI SAYA
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '📜 Riwayat Presensi Saya',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                  ),
                  IconButton(
                    icon: const Icon(Icons.refresh_rounded, size: 18, color: _kNavyDark),
                    onPressed: _loadHistory,
                  ),
                ],
              ),
              const SizedBox(height: 12),

              if (_loadingHistory)
                const Center(child: CircularProgressIndicator(color: _kNavyDark))
              else if (_myHistory.isEmpty)
                Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: _kNavyDark, width: 1.5),
                  ),
                  child: const Center(
                    child: Text('Belum ada catatan presensi yang terekam.', style: TextStyle(color: Colors.black54)),
                  ),
                )
              else
                ..._myHistory.map((h) {
                  final title = h['session_title'] ?? 'Presensi';
                  final week = h['week_number'] ?? 1;
                  final dateStr = h['attended_at']?.toString() ?? '-';
                  final className = h['class_name'] ?? '';
                  final status = (h['status'] ?? 'belum_hadir').toString().toLowerCase();
                  final source = h['source'] ?? (status == 'hadir' ? 'Scan QR / Dosen' : '-');
                  final notes = h['notes'];

                  Color cardBorderColor;
                  Color iconBgColor;
                  Color iconColor;
                  IconData iconData;
                  Color badgeBgColor;
                  Color badgeTextColor;
                  String badgeText;

                  if (status == 'hadir') {
                    cardBorderColor = const Color(0xFF059669);
                    iconBgColor = const Color(0xFFD1FAE5);
                    iconColor = const Color(0xFF059669);
                    iconData = Icons.check_circle_rounded;
                    badgeBgColor = const Color(0xFFD1FAE5);
                    badgeTextColor = const Color(0xFF065F46);
                    badgeText = 'HADIR';
                  } else if (status == 'sakit') {
                    cardBorderColor = const Color(0xFFD97706);
                    iconBgColor = const Color(0xFFFEF3C7);
                    iconColor = const Color(0xFFD97706);
                    iconData = Icons.medical_services_rounded;
                    badgeBgColor = const Color(0xFFFEF3C7);
                    badgeTextColor = const Color(0xFF92400E);
                    badgeText = 'SAKIT';
                  } else if (status == 'izin') {
                    cardBorderColor = const Color(0xFF2563EB);
                    iconBgColor = const Color(0xFFDBEAFE);
                    iconColor = const Color(0xFF2563EB);
                    iconData = Icons.info_rounded;
                    badgeBgColor = const Color(0xFFDBEAFE);
                    badgeTextColor = const Color(0xFF1E40AF);
                    badgeText = 'IZIN';
                  } else {
                    cardBorderColor = Colors.grey.shade400;
                    iconBgColor = Colors.grey.shade200;
                    iconColor = Colors.grey.shade600;
                    iconData = Icons.cancel_outlined;
                    badgeBgColor = Colors.grey.shade200;
                    badgeTextColor = Colors.black87;
                    badgeText = 'BELUM HADIR';
                  }

                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: cardBorderColor, width: 1.5),
                      boxShadow: [BoxShadow(color: cardBorderColor.withValues(alpha: 0.3), offset: const Offset(2, 2), blurRadius: 0)],
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: iconBgColor,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(iconData, color: iconColor, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(title, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 14, color: _kNavyDark)),
                              const SizedBox(height: 2),
                              Text('$className | Pekan $week | Sumber: $source', style: const TextStyle(fontSize: 11, color: Colors.black54, fontWeight: FontWeight.w600)),
                              if (dateStr != '-') ...[
                                const SizedBox(height: 2),
                                Text('Waktu: $dateStr', style: const TextStyle(fontSize: 11, color: Colors.black45)),
                              ],
                              if (notes != null && notes.toString().trim().isNotEmpty) ...[
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text('📝 $notes', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.grey.shade800)),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: badgeBgColor,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(badgeText, style: TextStyle(fontWeight: FontWeight.w900, fontSize: 11, color: badgeTextColor)),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
