import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
// ignore_for_file: avoid_web_libraries_in_flutter, uri_does_not_exist
import 'dart:html' as html;
import 'dart:js_util' as js_util;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/quizizz_service.dart';
import '../../services/socket_service.dart';
import '../../utils/qr_scanner_helper.dart';
import '../../widgets/session_qr_code.dart';

const Color _kCreamBg = Color(0xFFBDD8E9);
const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

class ResearchGroupsTab extends StatefulWidget {
  final String classId;
  final String className;
  final String? subject;
  final String? dosenId;

  const ResearchGroupsTab({
    super.key,
    required this.classId,
    required this.className,
    this.subject,
    this.dosenId,
  });

  @override
  State<ResearchGroupsTab> createState() => _ResearchGroupsTabState();
}

class _ResearchGroupsTabState extends State<ResearchGroupsTab> {
  bool _loading = true;
  List<Map<String, dynamic>> _groups = [];
  Map<String, dynamic> _classChatSummary = {
    'class_forum_unread': 0,
    'total_pm_unread': 0,
    'total_unread': 0,
  };
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadGroups();
    _setupSocketListeners();
    // Auto refresh every 4 seconds to keep chat badges, members, and group list up to date
    _refreshTimer = Timer.periodic(const Duration(seconds: 4), (_) => _loadGroups(silent: true));
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  void _setupSocketListeners() {
    try {
      final socket = SocketService.socket;
      if (socket != null) {
        socket.on('research_chat_notification', (_) {
          if (mounted) _loadGroups(silent: true);
        });
        socket.on('research_chat_message', (_) {
          if (mounted) _loadGroups(silent: true);
        });
        socket.on('class_chat_notification', (_) {
          if (mounted) _loadGroups(silent: true);
        });
        socket.on('class_chat_message', (_) {
          if (mounted) _loadGroups(silent: true);
        });
      }
    } catch (_) {}
  }

  String _formatGroupName(dynamic groupOrDoc, [int? fallbackIndex]) {
    if (groupOrDoc == null) return fallbackIndex != null ? 'Grup-$fallbackIndex' : 'Grup';
    
    final numVal = groupOrDoc['group_number'];
    if (numVal != null && numVal.toString().trim().isNotEmpty) {
      return 'Grup-${numVal.toString().trim()}';
    }
    
    final rawName = (groupOrDoc['group_name'] ?? groupOrDoc['name'] ?? '').toString().trim();
    final match = RegExp(r'(\d+)').firstMatch(rawName);
    if (match != null) {
      return 'Grup-${match.group(1)}';
    }
    
    if (rawName.isNotEmpty && rawName != 'Grup' && rawName != '-') {
      return rawName;
    }
    
    return fallbackIndex != null ? 'Grup-$fallbackIndex' : 'Grup';
  }

  Future<void> _loadGroups({bool silent = false}) async {
    if (!silent) setState(() => _loading = true);
    final data = await QuizizzService.getResearchGroupsWithSummary(widget.classId);
    if (!mounted) return;
    setState(() {
      final rawList = (data['groups'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      _groups = rawList.map((g) {
        return {
          ...g,
          'group_name': _formatGroupName(g),
        };
      }).toList();
      _classChatSummary = (data['class_chat_summary'] as Map?)?.cast<String, dynamic>() ?? {};
      _loading = false;
    });
  }

  bool get _isDosen {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    return auth.role == 'dosen';
  }

  void _openClassDiscussionDialog() {
    showDialog(
      context: context,
      builder: (_) => ClassDiscussionDialog(
        classId: widget.classId,
        className: widget.className,
        subject: widget.subject,
        dosenId: widget.dosenId,
      ),
    ).then((_) {
      _loadGroups(silent: true);
    });
  }

  // DOSEN: Tambah Grup Capstone Baru
  Future<void> _showAddGroupDialog() async {
    final titleCtrl = TextEditingController();
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final dosenName = auth.user?['full_name']?.toString() ?? 'Dr. GELAR BUDIMAN S.T., M.T.';
    final dosenPembimbing1Ctrl = TextEditingController(text: dosenName);
    final dosenPembimbing2Ctrl = TextEditingController();
    final dosenKelasCtrl = TextEditingController();

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: _kNavyDark, width: 2),
        ),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _kMustardYellow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: _kNavyDark, width: 1.5),
              ),
              child: const Icon(Icons.group_add_rounded, color: _kNavyDark, size: 22),
            ),
            const SizedBox(width: 12),
            const Text(
              '➕ Tambah Grup Capstone',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
            ),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Nomor grup akan dibuat secara otomatis bertambah (Grup 1, Grup 2, dst).',
                  style: TextStyle(fontSize: 12, color: Colors.black54),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Judul Tugas Akhir / Riset',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: titleCtrl,
                  maxLines: 3,
                  decoration: InputDecoration(
                    hintText: 'Contoh: Implementasi Steganografi Audio Berbasis Deep Learning...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _kNavyDark),
                    ),
                    contentPadding: const EdgeInsets.all(12),
                  ),
                ),
                const SizedBox(height: 14),

                // DOSEN PEMBIMBING 1
                const Text(
                  'Dosen Pembimbing 1',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: dosenPembimbing1Ctrl,
                  decoration: InputDecoration(
                    hintText: 'Nama Dosen Pembimbing 1...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _kNavyDark),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),

                // DOSEN PEMBIMBING 2 (OPSIONAL)
                const Text(
                  'Dosen Pembimbing 2 (Opsional)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: dosenPembimbing2Ctrl,
                  decoration: InputDecoration(
                    hintText: 'Nama Dosen Pembimbing 2 (jika ada)...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _kNavyDark),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
                const SizedBox(height: 14),

                // DOSEN KELAS (OPSIONAL & DAPAT DIISI/DIEDIT)
                const Text(
                  'Dosen Kelas (Opsional)',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: dosenKelasCtrl,
                  decoration: InputDecoration(
                    hintText: 'Ketik nama Dosen Kelas (dapat diisi mahasiswa/dosen)...',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _kNavyDark),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () async {
              final title = titleCtrl.text.trim();
              if (title.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Judul Tugas Akhir wajib diisi')),
                );
                return;
              }
              try {
                final newGrp = await QuizizzService.createResearchGroup(
                  widget.classId,
                  title: title,
                  dosenPembimbing1: dosenPembimbing1Ctrl.text.trim(),
                  dosenPembimbing2: dosenPembimbing2Ctrl.text.trim(),
                  dosenKelas: dosenKelasCtrl.text.trim(),
                );
                if (ctx.mounted) {
                  Navigator.pop(ctx, true);
                  if (newGrp != null) {
                    _showViewGroupDialog(newGrp);
                  }
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(
                    SnackBar(content: Text('Gagal membuat grup: $e')),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: _kNavyDark,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            ),
            child: const Text('Simpan Grup', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (created == true) _loadGroups();
  }

  Future<void> _copyQrImageToClipboard(String qrPayload, String groupName) async {
    try {
      final qrValidationResult = QrValidator.validate(
        data: qrPayload,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.L,
      );
      if (qrValidationResult.status == QrValidationStatus.valid) {
        final qrCode = qrValidationResult.qrCode!;
        final painter = QrPainter.withQr(
          qr: qrCode,
          gapless: true,
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Color(0xFF001D39),
          ),
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Color(0xFF001D39),
          ),
        );
        final picData = await painter.toImageData(320, format: ui.ImageByteFormat.png);
        if (picData != null) {
          final bytes = picData.buffer.asUint8List();
          if (kIsWeb) {
            final base64String = 'data:image/png;base64,${base64Encode(bytes)}';
            try {
              if (js_util.hasProperty(html.window, 'copyImageToClipboard')) {
                await js_util.promiseToFuture(
                  js_util.callMethod(html.window, 'copyImageToClipboard', [base64String]),
                );
              } else {
                final blob = html.Blob([bytes], 'image/png');
                final clipboardItemConstructor = js_util.getProperty(html.window, 'ClipboardItem');
                final itemObj = js_util.newObject();
                js_util.setProperty(itemObj, 'image/png', blob);
                final clipboardItem = js_util.callConstructor(clipboardItemConstructor, [itemObj]);
                final clipboard = js_util.getProperty(html.window.navigator, 'clipboard');
                await js_util.promiseToFuture(
                  js_util.callMethod(clipboard, 'write', [ [clipboardItem] ]),
                );
              }

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('✅ Gambar QR Code berhasil disalin ke clipboard! Silakan tempel (Ctrl+V / Cmd+V).'),
                    backgroundColor: Color(0xFF059669),
                    duration: Duration(seconds: 3),
                  ),
                );
              }
              return;
            } catch (copyErr) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Gagal menyalin gambar ke clipboard: $copyErr'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              }
              return;
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memproses gambar QR: $e')),
        );
      }
    }
  }

  Future<void> _downloadQrImage(String qrPayload, String groupName) async {
    try {
      final qrValidationResult = QrValidator.validate(
        data: qrPayload,
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.L,
      );
      if (qrValidationResult.status == QrValidationStatus.valid) {
        final qrCode = qrValidationResult.qrCode!;
        final painter = QrPainter.withQr(
          qr: qrCode,
          gapless: true,
          dataModuleStyle: const QrDataModuleStyle(
            dataModuleShape: QrDataModuleShape.square,
            color: Color(0xFF001D39),
          ),
          eyeStyle: const QrEyeStyle(
            eyeShape: QrEyeShape.square,
            color: Color(0xFF001D39),
          ),
        );
        final picData = await painter.toImageData(512, format: ui.ImageByteFormat.png);
        if (picData != null) {
          final bytes = picData.buffer.asUint8List();
          final sanitizedName = groupName.replaceAll(RegExp(r'[^\w\s\-]'), '_').replaceAll(RegExp(r'\s+'), '_').trim();
          final fileName = 'QR_Grup_${sanitizedName.isEmpty ? "Riset" : sanitizedName}.png';

          if (kIsWeb) {
            final blob = html.Blob([bytes], 'image/png');
            final url = html.Url.createObjectUrlFromBlob(blob);
            html.AnchorElement(href: url)
              ..setAttribute('download', fileName)
              ..click();
            html.Url.revokeObjectUrl(url);
          }

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ File $fileName berhasil diunduh!'),
                backgroundColor: const Color(0xFF059669),
                duration: const Duration(seconds: 3),
              ),
            );
          }
          return;
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengunduh gambar QR: $e')),
        );
      }
    }
  }

  // DOSEN & MAHASISWA: View Detail Grup + QR Code & Kode Join
  void _showViewGroupDialog(Map<String, dynamic> group) {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          final screenWidth = MediaQuery.of(ctx).size.width;
          final isMobile = screenWidth < 550;

          // Find fresh data for this group from state
          final liveGroup = _groups.firstWhere((g) => g['id'] == group['id'], orElse: () => group);
          final members = (liveGroup['members'] as List?)?.cast<Map<String, dynamic>>() ?? [];
          final qrPayload = liveGroup['qr_data'] ?? liveGroup['group_code'] ?? '';
          final groupName = liveGroup['group_name'] ?? 'Grup';
          final groupCode = liveGroup['group_code'] ?? '-';
          final title = liveGroup['title'] ?? '-';

          final qrWidget = Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _kNavyDark, width: 1.5),
              boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(3, 3), blurRadius: 0)],
            ),
            child: Column(
              children: [
                SessionQrCode(
                  code: qrPayload,
                  color: _kNavyDark,
                  label: 'Scan QR untuk Join Grup',
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _copyQrImageToClipboard(qrPayload, groupName),
                      icon: const Icon(Icons.copy_rounded, size: 13),
                      label: const Text('Salin QR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFEFF6FF),
                        foregroundColor: const Color(0xFF1D4ED8),
                        elevation: 0,
                        side: const BorderSide(color: Color(0xFF93C5FD), width: 1.2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _downloadQrImage(qrPayload, groupName),
                      icon: const Icon(Icons.download_rounded, size: 14),
                      label: const Text('Unduh File QR', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFF0FDF4),
                        foregroundColor: const Color(0xFF15803D),
                        elevation: 0,
                        side: const BorderSide(color: Color(0xFF86EFAC), width: 1.2),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );

          final codeDetailsWidget = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('KODE GRUP:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
              const SizedBox(height: 4),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                decoration: BoxDecoration(
                  color: _kMustardYellow,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _kNavyDark, width: 1.5),
                ),
                child: Center(
                  child: Text(
                    groupCode,
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark, letterSpacing: 2),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: groupCode));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ Kode grup berhasil disalin!')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 14),
                    label: const Text('Salin Kode', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kNavyDark,
                      side: const BorderSide(color: _kNavyDark, width: 1.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      final inviteText = 'Halo rekan tim, silakan bergabung ke kelas riset $groupName:\n'
                          'Judul: $title\n'
                          'Kode Join: $groupCode\n'
                          'Buka aplikasi Classly di menu "Join Kelas" lalu masukkan kode di atas.';
                      Clipboard.setData(ClipboardData(text: inviteText));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ Format undangan lengkap berhasil disalin!')),
                      );
                    },
                    icon: const Icon(Icons.share_rounded, size: 14),
                    label: const Text('Salin Undangan Tim', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kNavyDark,
                      side: const BorderSide(color: _kNavyDark, width: 1.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Mahasiswa dapat scan QR ini atau memasukkan kode di menu "Join Kelas" untuk langsung masuk ke grup ini.',
                style: TextStyle(fontSize: 10, color: Colors.black54, height: 1.2),
              ),
            ],
          );

          return Dialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: _kNavyDark, width: 2),
            ),
            insetPadding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 540),
              child: SingleChildScrollView(
                padding: EdgeInsets.all(isMobile ? 16 : 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // TOP BAR
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                              decoration: BoxDecoration(
                                color: _kMustardYellow,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: _kNavyDark, width: 1.5),
                              ),
                              child: Text(
                                groupName,
                                style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 13),
                              ),
                            ),
                            const SizedBox(width: 10),
                            const Text('Detail Grup Capstone', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark)),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.close_rounded, color: _kNavyDark),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    // Judul TA
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: _kNavyDark, width: 1.2),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('JUDUL TUGAS AKHIR / RISET:', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black54)),
                          const SizedBox(height: 4),
                          Text(
                            title,
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13, color: _kNavyDark),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),

                    // 1. Dosen Pembimbing 1
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF93C5FD), width: 1.2),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFDBEAFE),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF2563EB)),
                            ),
                            child: const Icon(Icons.person_pin_rounded, color: Color(0xFF1D4ED8), size: 16),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('DOSEN PEMBIMBING 1:', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8))),
                                const SizedBox(height: 2),
                                Text(
                                  liveGroup['dosen_pembimbing_1'] ?? liveGroup['dosen_pembimbing'] ?? 'Dr. GELAR BUDIMAN S.T., M.T.',
                                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 12, color: _kNavyDark),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),

                    // 2. Dosen Pembimbing 2
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF5F3FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFDDD6FE), width: 1.2),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEDE9FE),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF7C3AED)),
                            ),
                            child: const Icon(Icons.person_outline_rounded, color: Color(0xFF6D28D9), size: 16),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('DOSEN PEMBIMBING 2:', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF6D28D9))),
                                const SizedBox(height: 2),
                                Text(
                                  (liveGroup['dosen_pembimbing_2'] != null && liveGroup['dosen_pembimbing_2'].toString().trim().isNotEmpty)
                                      ? liveGroup['dosen_pembimbing_2']
                                      : 'Belum diisi (Dapat diisi via tombol Edit)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                    color: (liveGroup['dosen_pembimbing_2'] != null && liveGroup['dosen_pembimbing_2'].toString().trim().isNotEmpty) ? _kNavyDark : Colors.black45,
                                    fontStyle: (liveGroup['dosen_pembimbing_2'] != null && liveGroup['dosen_pembimbing_2'].toString().trim().isNotEmpty) ? FontStyle.normal : FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),

                    // 3. Dosen Kelas
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFECFDF5),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFF10B981), width: 1.2),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFFD1FAE5),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: const Color(0xFF059669)),
                            ),
                            child: const Icon(Icons.school_rounded, color: Color(0xFF065F46), size: 16),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('DOSEN KELAS:', style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF065F46))),
                                const SizedBox(height: 2),
                                Text(
                                  (liveGroup['dosen_kelas'] != null && liveGroup['dosen_kelas'].toString().trim().isNotEmpty)
                                      ? liveGroup['dosen_kelas']
                                      : 'Belum diisi (Dapat diisi via tombol Edit)',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    fontSize: 12,
                                    color: (liveGroup['dosen_kelas'] != null && liveGroup['dosen_kelas'].toString().trim().isNotEmpty) ? _kNavyDark : Colors.black45,
                                    fontStyle: (liveGroup['dosen_kelas'] != null && liveGroup['dosen_kelas'].toString().trim().isNotEmpty) ? FontStyle.normal : FontStyle.italic,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // KODE GRUP & QR CODE (RESPONSIVE)
                    if (isMobile) ...[
                      Center(child: qrWidget),
                      const SizedBox(height: 14),
                      codeDetailsWidget,
                    ] else ...[
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: qrWidget),
                          const SizedBox(width: 14),
                          Expanded(flex: 6, child: codeDetailsWidget),
                        ],
                      ),
                    ],
                    const SizedBox(height: 18),

                    // TABEL ANGGOTA MAHASISWA
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Anggota Tim (${members.length} Mahasiswa)',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
                        ),
                        IconButton(
                          icon: const Icon(Icons.refresh_rounded, size: 18, color: _kNavyDark),
                          tooltip: 'Segarkan data anggota',
                          onPressed: () async {
                            await _loadGroups(silent: true);
                            setModalState(() {});
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    SelectionArea(
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: _kNavyDark, width: 1.2),
                        ),
                        child: members.isEmpty
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(
                                  child: Text('Belum ada mahasiswa yang bergabung ke grup ini.', style: TextStyle(fontSize: 12, color: Colors.black45)),
                                ),
                              )
                            : ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: members.length,
                                separatorBuilder: (c, i) => const Divider(height: 1, color: Colors.black12),
                                itemBuilder: (ctx, idx) {
                                  final m = members[idx];
                                  return ListTile(
                                    dense: true,
                                    leading: CircleAvatar(
                                      radius: 14,
                                      backgroundColor: _kNavyDark,
                                      child: Text('${idx + 1}', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.bold)),
                                    ),
                                    title: Text(m['student_name'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                                    subtitle: Text('NIM: ${m['nim'] ?? '-'}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                                    trailing: _isDosen
                                        ? IconButton(
                                            icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                                            tooltip: 'Keluarkan mahasiswa ini dari grup',
                                            onPressed: () {
                                              _confirmRemoveMember(liveGroup['id'], m, () async {
                                                await _loadGroups(silent: true);
                                                setModalState(() {});
                                              });
                                            },
                                          )
                                        : const Icon(Icons.check_circle_rounded, color: Color(0xFF059669), size: 16),
                                  );
                                },
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // TOMBOL BUKA DISKUSI
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _openDiscussionDialog(liveGroup);
                        },
                        icon: const Icon(Icons.chat_bubble_rounded, size: 16),
                        label: const Text('Buka Diskusi Grup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _kNavyDark,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // DOSEN: Dialog Konfirmasi Keluarkan Mahasiswa dari Grup
  Future<void> _confirmRemoveMember(String groupId, Map<String, dynamic> member, VoidCallback onSuccess) async {
    final studentName = member['student_name'] ?? member['full_name'] ?? 'Mahasiswa ini';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Row(
          children: [
            Icon(Icons.person_remove_rounded, color: Colors.redAccent, size: 22),
            SizedBox(width: 10),
            Text('Keluarkan Mahasiswa?', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark)),
          ],
        ),
        content: Text(
          'Apakah Anda yakin ingin mengeluarkan "$studentName" (NIM: ${member['nim'] ?? '-'}) dari grup ini?\n\nMahasiswa yang dikeluarkan dapat bergabung kembali ke grup lain.',
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal', style: TextStyle(color: _kNavyDark, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Ya, Keluarkan', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      final sId = member['student_id']?.toString() ?? member['id']?.toString() ?? '';
      final ok = await QuizizzService.removeResearchGroupMember(groupId, sId);
      if (ok) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('✅ $studentName berhasil dikeluarkan dari grup.'), backgroundColor: const Color(0xFF059669)),
          );
        }
        onSuccess();
        _loadGroups(silent: true);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('❌ Gagal mengeluarkan mahasiswa dari grup.'), backgroundColor: Colors.redAccent),
          );
        }
      }
    }
  }

  // DOSEN & MAHASISWA: Edit Judul / Dosen Pembimbing / Dosen Kelas / Nama Grup & Kelola/Hapus Anggota
  Future<void> _showEditGroupDialog(Map<String, dynamic> group) async {
    final isDosen = _isDosen;
    final titleCtrl = TextEditingController(text: group['title'] ?? '');
    final nameCtrl = TextEditingController(text: group['group_name'] ?? '');
    final dosenPembimbing1Ctrl = TextEditingController(
      text: group['dosen_pembimbing_1'] ?? group['dosen_pembimbing'] ?? 'Dr. GELAR BUDIMAN S.T., M.T.',
    );
    final dosenPembimbing2Ctrl = TextEditingController(
      text: group['dosen_pembimbing_2'] ?? '',
    );
    final dosenKelasCtrl = TextEditingController(text: group['dosen_kelas'] ?? '');

    final updated = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final liveGroup = _groups.firstWhere((g) => g['id'] == group['id'], orElse: () => group);
          final members = (liveGroup['members'] as List?)?.cast<Map<String, dynamic>>() ?? [];

          return AlertDialog(
            backgroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: _kMustardYellow, borderRadius: BorderRadius.circular(10), border: Border.all(color: _kNavyDark, width: 1.5)),
                  child: const Icon(Icons.edit_note_rounded, color: _kNavyDark, size: 22),
                ),
                const SizedBox(width: 10),
                Text(
                  isDosen ? '✏️ Edit Grup Capstone' : '✏️ Edit Judul & Dosen',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: _kNavyDark),
                ),
              ],
            ),
            content: SizedBox(
              width: 480,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (isDosen) ...[
                      const Text('Nama Grup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                      const SizedBox(height: 6),
                      TextField(
                        controller: nameCtrl,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    const Text('Judul Tugas Akhir / Riset', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: titleCtrl,
                      maxLines: 3,
                      decoration: InputDecoration(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                        contentPadding: const EdgeInsets.all(12),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 1. Dosen Pembimbing 1 (Editable)
                    const Text('Dosen Pembimbing 1', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: dosenPembimbing1Ctrl,
                      decoration: InputDecoration(
                        hintText: 'Nama Dosen Pembimbing 1...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 2. Dosen Pembimbing 2 (Editable)
                    const Text('Dosen Pembimbing 2 (Opsional)', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: dosenPembimbing2Ctrl,
                      decoration: InputDecoration(
                        hintText: 'Nama Dosen Pembimbing 2 (jika ada)...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 14),

                    // 3. Dosen Kelas (Editable)
                    const Text('Dosen Kelas', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: dosenKelasCtrl,
                      decoration: InputDecoration(
                        hintText: 'Ketik nama Dosen Kelas (dapat diisi/diubah)...',
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: _kNavyDark)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // DAFTAR ANGGOTA
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Anggota Mahasiswa (${members.length})',
                          style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 13, color: _kNavyDark),
                        ),
                        if (isDosen && members.isNotEmpty)
                          const Text(
                            'Klik 🗑️ untuk mengeluarkan',
                            style: TextStyle(fontSize: 10, color: Colors.black45, fontStyle: FontStyle.italic),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF8FAFC),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFCBD5E1)),
                      ),
                      child: members.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(
                                child: Text('Belum ada mahasiswa di grup ini.', style: TextStyle(fontSize: 12, color: Colors.black45)),
                              ),
                            )
                          : ListView.separated(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: members.length,
                              separatorBuilder: (c, i) => const Divider(height: 1, color: Colors.black12),
                              itemBuilder: (c, idx) {
                                final m = members[idx];
                                return ListTile(
                                  dense: true,
                                  leading: CircleAvatar(
                                    radius: 13,
                                    backgroundColor: _kNavyDark,
                                    child: Text('${idx + 1}', style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                  title: Text(m['student_name'] ?? '-', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: _kNavyDark)),
                                  subtitle: Text('NIM: ${m['nim'] ?? '-'}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                                  trailing: isDosen
                                      ? IconButton(
                                          icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                                          tooltip: 'Keluarkan mahasiswa ini dari grup',
                                          onPressed: () {
                                            _confirmRemoveMember(group['id'], m, () async {
                                              await _loadGroups(silent: true);
                                              setDialogState(() {});
                                            });
                                          },
                                        )
                                      : const Icon(Icons.check_circle_rounded, color: Color(0xFF059669), size: 16),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: _kNavyDark))),
              ElevatedButton(
                onPressed: () async {
                  if (titleCtrl.text.trim().isEmpty) {
                    ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('Judul Tugas Akhir wajib diisi')));
                    return;
                  }
                  final ok = await QuizizzService.updateResearchGroup(
                    group['id'],
                    title: titleCtrl.text.trim(),
                    groupName: isDosen ? nameCtrl.text.trim() : null,
                    dosenPembimbing1: dosenPembimbing1Ctrl.text.trim(),
                    dosenPembimbing2: dosenPembimbing2Ctrl.text.trim(),
                    dosenKelas: dosenKelasCtrl.text.trim(),
                  );
                  if (ctx.mounted) {
                    Navigator.pop(ctx, ok);
                    if (ok) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('✅ Data grup berhasil diperbarui!'), backgroundColor: Color(0xFF059669)),
                      );
                    }
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: _kNavyDark, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                child: const Text('Simpan Perubahan', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );

    if (updated == true) _loadGroups();
  }

  // DOSEN: Hapus Grup
  Future<void> _deleteGroup(Map<String, dynamic> group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: const BorderSide(color: _kNavyDark, width: 2)),
        title: const Text('🗑️ Hapus Grup Capstone', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.red)),
        content: Text('Apakah Anda yakin ingin menghapus "${group['group_name']}"?\nSeluruh data anggota, riwayat diskusi, dan dokumen terkait akan dihapus permanen.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Batal', style: TextStyle(color: _kNavyDark))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade700, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            child: const Text('Ya, Hapus', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await QuizizzService.deleteResearchGroup(group['id']);
      _loadGroups();
    }
  }

  // Buka Dialog Diskusi (WhatsApp-like)
  void _openDiscussionDialog(Map<String, dynamic> group) {
    showDialog(
      context: context,
      builder: (_) => ResearchDiscussionDialog(
        groupId: group['id'],
        groupName: group['group_name'] ?? 'Grup',
        title: group['title'] ?? '',
        classId: widget.classId,
        members: (group['members'] as List?)?.cast<Map<String, dynamic>>() ?? [],
        dosenId: widget.dosenId,
      ),
    ).then((_) {
      _loadGroups(silent: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDosen = _isDosen;

    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: _kNavyDark));
    }

    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // BANNER STATISTIK / HEADER
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: _kNavyDark, width: 2),
                boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _kMustardYellow,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: _kNavyDark, width: 1.5),
                        ),
                        child: const Icon(Icons.groups_rounded, color: _kNavyDark, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isDosen
                                ? 'Grup Capstone & Riset (${_groups.length} Grup)'
                                : 'Grup Capstone Saya',
                            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18, color: _kNavyDark),
                          ),
                          Text(
                            'Kelas: ${widget.className} — ${widget.subject ?? 'Riset TA'}',
                            style: const TextStyle(fontSize: 12, color: Colors.black54, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ],
                  ),
                  if (isDosen)
                    ElevatedButton.icon(
                      onPressed: _showAddGroupDialog,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kNavyDark,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      ),
                      icon: const Icon(Icons.add_rounded, size: 20),
                      label: const Text('Tambah Grup', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 18),

            // BANNER RUANG DISKUSI SELURUH KELAS & PESAN PRIBADI
            _buildClassDiscussionBanner(),
            const SizedBox(height: 20),

            // KONTEN GRUP: MAHASISWA HANYA LIHAT KARTU GRUPNYA, DOSEN LIHAT SEMUA DAFTAR GRUP
            if (!isDosen) ...[
              _buildMahasiswaGroupOverview(),
            ] else ...[
              if (_groups.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _kNavyDark, width: 1.5),
                  ),
                  child: const Center(
                    child: Column(
                      children: [
                        Icon(Icons.folder_shared_rounded, size: 48, color: Colors.black26),
                        SizedBox(height: 12),
                        Text(
                          'Belum ada grup capstone. Klik "Tambah Grup" untuk membuat grup riset.',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 13, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ListView.separated(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _groups.length,
                  separatorBuilder: (c, i) => const SizedBox(height: 14),
                  itemBuilder: (ctx, idx) {
                    final grp = _groups[idx];
                    return _buildGroupCard(grp);
                  },
                ),
            ],
          ],
        ),
      ),
    );
  }

  // Tampilan Banner Ruang Diskusi Kelas & Chat Japri (Untuk Dosen & Mahasiswa)
  Widget _buildClassDiscussionBanner() {
    final totalUnread = _classChatSummary['total_unread'] ?? 0;
    final forumUnread = _classChatSummary['class_forum_unread'] ?? 0;
    final pmUnread = _classChatSummary['total_pm_unread'] ?? 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFF0FDF4),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF059669), width: 2),
        boxShadow: const [BoxShadow(color: Color(0xFF059669), offset: Offset(4, 4), blurRadius: 0)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF059669),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Icon(Icons.forum_rounded, color: Colors.white, size: 28),
                  ),
                  if (totalUnread > 0)
                    Positioned(
                      right: -4,
                      top: -4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Text(
                          '$totalUnread',
                          style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            '💬 Ruang Diskusi & Pesan Pribadi',
                            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                          ),
                        ),
                        if (totalUnread > 0) ...[
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.red,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$totalUnread Baru',
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Forum interaktif seluruh kelas & Pesan Pribadi (1-on-1) antar mahasiswa dan dosen',
                      style: TextStyle(fontSize: 12, color: Colors.black87, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFA7F3D0)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: forumUnread > 0 ? const Color(0xFFDCFCE7) : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: forumUnread > 0 ? const Color(0xFF16A34A) : Colors.black12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.campaign_rounded, size: 14, color: Color(0xFF166534)),
                        const SizedBox(width: 4),
                        Text(
                          forumUnread > 0 ? 'Forum ($forumUnread Baru)' : 'Forum Kelas',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: forumUnread > 0 ? const Color(0xFF166534) : Colors.black87),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: pmUnread > 0 ? const Color(0xFFEFF6FF) : Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: pmUnread > 0 ? const Color(0xFF2563EB) : Colors.black12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.person_pin_rounded, size: 14, color: Color(0xFF1E40AF)),
                        const SizedBox(width: 4),
                        Text(
                          pmUnread > 0 ? 'Pesan Pribadi ($pmUnread Baru)' : 'Pesan Pribadi',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: pmUnread > 0 ? const Color(0xFF1E40AF) : Colors.black87),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: _openClassDiscussionDialog,
                icon: const Icon(Icons.chat_bubble_rounded, size: 15),
                label: Text(
                  totalUnread > 0 ? 'Buka Chat ($totalUnread)' : 'Buka Chat',
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _kNavyDark,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // Tampilan ringkasan grup khusus mahasiswa
  Widget _buildMahasiswaGroupOverview() {
    final myGroup = _groups.firstWhere(
      (g) => g['is_my_group'] == true,
      orElse: () => <String, dynamic>{},
    );

    if (myGroup.isEmpty) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFFFEF3C7),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFD97706), width: 1.5),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_rounded, color: Color(0xFFB45309), size: 24),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Anda belum tergabung dalam grup riset di kelas ini. Scan QR code grup dari rekan tim Anda atau hubungi Dosen.',
                style: TextStyle(fontSize: 12, color: Color(0xFF78350F), fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
      );
    }

    final members = (myGroup['members'] as List?)?.cast<Map<String, dynamic>>() ?? [];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFFECFDF5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF059669), width: 2),
        boxShadow: const [BoxShadow(color: Color(0xFF059669), offset: Offset(3, 3), blurRadius: 0)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF059669),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text('GRUP ANDA', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    myGroup['group_name'] ?? 'Grup',
                    style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: _kNavyDark),
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _openDiscussionDialog(myGroup),
                    icon: const Icon(Icons.chat_rounded, size: 16),
                    label: Text(
                      (myGroup['unread_count'] ?? 0) > 0 ? 'Diskusi (${myGroup['unread_count']})' : 'Diskusi Tim',
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kNavyDark,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _showViewGroupDialog(myGroup),
                    icon: const Icon(Icons.visibility_rounded, size: 15),
                    label: const Text('View', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kNavyDark,
                      side: const BorderSide(color: _kNavyDark, width: 1.4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _showEditGroupDialog(myGroup),
                    icon: const Icon(Icons.edit_note_rounded, size: 16, color: Color(0xFF1D4ED8)),
                    label: const Text('Edit', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Color(0xFF1D4ED8))),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1D4ED8),
                      side: const BorderSide(color: Color(0xFF1D4ED8), width: 1.4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            myGroup['title'] ?? '-',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: _kNavyDark),
          ),
          const SizedBox(height: 10),
          // DOSEN PEMBIMBING 1, 2 & DOSEN KELAS ROW
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_pin_rounded, size: 14, color: Color(0xFF1D4ED8)),
                    const SizedBox(width: 6),
                    const Text(
                      'Pembimbing 1: ',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8)),
                    ),
                    Flexible(
                      child: Text(
                        myGroup['dosen_pembimbing_1'] ?? myGroup['dosen_pembimbing'] ?? 'Dr. GELAR BUDIMAN S.T., M.T.',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _kNavyDark),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (myGroup['dosen_pembimbing_2'] != null && myGroup['dosen_pembimbing_2'].toString().trim().isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F3FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFDDD6FE)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person_outline_rounded, size: 14, color: Color(0xFF6D28D9)),
                      const SizedBox(width: 6),
                      const Text(
                        'Pembimbing 2: ',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF6D28D9)),
                      ),
                      Flexible(
                        child: Text(
                          myGroup['dosen_pembimbing_2'],
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _kNavyDark),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFA7F3D0)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.school_rounded, size: 14, color: Color(0xFF065F46)),
                    const SizedBox(width: 6),
                    const Text(
                      'Dosen Kelas: ',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF065F46)),
                    ),
                    Flexible(
                      child: Text(
                        (myGroup['dosen_kelas'] != null && myGroup['dosen_kelas'].toString().trim().isNotEmpty)
                            ? myGroup['dosen_kelas']
                            : '-',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: (myGroup['dosen_kelas'] != null && myGroup['dosen_kelas'].toString().trim().isNotEmpty) ? _kNavyDark : Colors.black45,
                          fontStyle: (myGroup['dosen_kelas'] != null && myGroup['dosen_kelas'].toString().trim().isNotEmpty) ? FontStyle.normal : FontStyle.italic,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1, color: Color(0xFFA7F3D0)),
          const SizedBox(height: 10),
          const Text('Rekan Anggota Tim:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: members.map((m) {
              return Chip(
                avatar: CircleAvatar(
                  backgroundColor: _kNavyDark,
                  child: Text(
                    (m['student_name'] ?? 'M')[0].toUpperCase(),
                    style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                label: Text('${m['student_name']} (${m['nim']})', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kNavyDark)),
                backgroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Color(0xFF059669), width: 1),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // Card Grup
  Widget _buildGroupCard(Map<String, dynamic> grp) {
    final members = (grp['members'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final unreadCount = (grp['unread_count'] as num?)?.toInt() ?? 0;
    final isDosen = _isDosen;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _kNavyDark, width: 1.8),
        boxShadow: const [BoxShadow(color: _kNavyDark, offset: Offset(4, 4), blurRadius: 0)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: _kMustardYellow,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _kNavyDark, width: 1.2),
                    ),
                    child: Text(
                      grp['group_name'] ?? 'Grup',
                      style: const TextStyle(fontWeight: FontWeight.w900, color: _kNavyDark, fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${members.length} Mahasiswa',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: _kNavyDark),
                    ),
                  ),
                ],
              ),

              // ACTION BUTTONS DI KANAN
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  // TOMBOL DISKUSI (dengan unread badge)
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => _openDiscussionDialog(grp),
                        icon: const Icon(Icons.forum_rounded, size: 15),
                        label: const Text('Diskusi', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: unreadCount > 0 ? const Color(0xFF059669) : _kNavyDark,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        ),
                      ),
                      if (unreadCount > 0)
                        Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.all(5),
                            decoration: const BoxDecoration(
                              color: Colors.red,
                              shape: BoxShape.circle,
                            ),
                            child: Text(
                              '$unreadCount',
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                    ],
                  ),

                  // VIEW BUTTON
                  OutlinedButton.icon(
                    onPressed: () => _showViewGroupDialog(grp),
                    icon: const Icon(Icons.visibility_rounded, size: 15),
                    label: const Text('View', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kNavyDark,
                      side: const BorderSide(color: _kNavyDark, width: 1.4),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                  ),

                  if (isDosen) ...[
                    IconButton(
                      icon: const Icon(Icons.edit_rounded, size: 18, color: _kNavyDark),
                      tooltip: 'Edit Grup & Anggota',
                      onPressed: () => _showEditGroupDialog(grp),
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                    ),
                    IconButton(
                      icon: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade700),
                      tooltip: 'Hapus Grup',
                      onPressed: () => _deleteGroup(grp),
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                    ),
                  ] else ...[
                    IconButton(
                      icon: const Icon(Icons.edit_note_rounded, size: 20, color: Color(0xFF1D4ED8)),
                      tooltip: 'Edit Judul & Dosen',
                      onPressed: () => _showEditGroupDialog(grp),
                      padding: const EdgeInsets.all(6),
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),

          // JUDUL TA
          Text(
            grp['title'] ?? '-',
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, color: _kNavyDark, height: 1.3),
          ),
          const SizedBox(height: 8),

          // DOSEN PEMBIMBING 1, 2 & DOSEN KELAS ROW
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFEFF6FF),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFBFDBFE)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_pin_rounded, size: 14, color: Color(0xFF1D4ED8)),
                    const SizedBox(width: 6),
                    const Text(
                      'Pembimbing 1: ',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF1D4ED8)),
                    ),
                    Flexible(
                      child: Text(
                        grp['dosen_pembimbing_1'] ?? grp['dosen_pembimbing'] ?? 'Dr. GELAR BUDIMAN S.T., M.T.',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _kNavyDark),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              if (grp['dosen_pembimbing_2'] != null && grp['dosen_pembimbing_2'].toString().trim().isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F3FF),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFDDD6FE)),
                  ),
                  child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_outline_rounded, size: 14, color: Color(0xFF6D28D9)),
                    const SizedBox(width: 6),
                    const Text(
                      'Pembimbing 2: ',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF6D28D9)),
                    ),
                    Flexible(
                      child: Text(
                        grp['dosen_pembimbing_2'],
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: _kNavyDark),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFECFDF5),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFA7F3D0)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.school_rounded, size: 14, color: Color(0xFF065F46)),
                    const SizedBox(width: 6),
                    const Text(
                      'Dosen Kelas: ',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF065F46)),
                    ),
                    Flexible(
                      child: Text(
                        (grp['dosen_kelas'] != null && grp['dosen_kelas'].toString().trim().isNotEmpty)
                            ? grp['dosen_kelas']
                            : '-',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: (grp['dosen_kelas'] != null && grp['dosen_kelas'].toString().trim().isNotEmpty) ? _kNavyDark : Colors.black45,
                          fontStyle: (grp['dosen_kelas'] != null && grp['dosen_kelas'].toString().trim().isNotEmpty) ? FontStyle.normal : FontStyle.italic,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // LIST ANGGOTA CHIPS
          if (members.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: members.map((m) {
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.black12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person_rounded, size: 14, color: _kNavyDark),
                      const SizedBox(width: 4),
                      Text(
                        '${m['student_name']} (${m['nim']})',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kNavyDark),
                      ),
                    ],
                  ),
                );
              }).toList(),
            )
          else
            const Text(
              'Belum ada anggota mahasiswa.',
              style: TextStyle(fontSize: 11, color: Colors.black45, fontStyle: FontStyle.italic),
            ),
        ],
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// DIALOG DISKUSI GRUP & JAPRI (ALA WHATSAPP)
// ----------------------------------------------------------------------------
class ResearchDiscussionDialog extends StatefulWidget {
  final String groupId;
  final String groupName;
  final String title;
  final String classId;
  final List<Map<String, dynamic>> members;
  final String? dosenId;

  const ResearchDiscussionDialog({
    super.key,
    required this.groupId,
    required this.groupName,
    required this.title,
    required this.classId,
    required this.members,
    this.dosenId,
  });

  @override
  State<ResearchDiscussionDialog> createState() => _ResearchDiscussionDialogState();
}

class _ResearchDiscussionDialogState extends State<ResearchDiscussionDialog> {
  bool _loading = true;
  List<Map<String, dynamic>> _discussions = [];
  final TextEditingController _msgCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  String? _selectedRecipientId; // null = Broadcast Grup, otherwise student_id/dosen_id for Private Message
  bool _isRecording = false;
  String _baseTextBeforeRecording = '';

  @override
  void initState() {
    super.initState();
    _loadDiscussions();
    _markRead();
    _setupSocket();
  }

  @override
  void dispose() {
    if (_isRecording) {
      QrScannerHelper.stopSpeechToText();
    }
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _setupSocket() {
    try {
      final socket = SocketService.socket;
      if (socket != null) {
        socket.on('research_chat_message', (data) {
          if (!mounted) return;
          if (data != null && data['group_id'] == widget.groupId) {
            setState(() {
              _discussions.add(Map<String, dynamic>.from(data));
            });
            _scrollToBottom();
            _markRead();
          }
        });
      }
    } catch (_) {}
  }

  Future<void> _loadDiscussions() async {
    setState(() => _loading = true);
    final list = await QuizizzService.getResearchDiscussions(widget.groupId);
    if (!mounted) return;
    setState(() {
      _discussions = list;
      _loading = false;
    });
    _scrollToBottom();
  }

  Future<void> _markRead() async {
    await QuizizzService.markResearchDiscussionRead(widget.groupId);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleSpeech() {
    if (_isRecording) {
      QrScannerHelper.stopSpeechToText();
      setState(() => _isRecording = false);
    } else {
      _baseTextBeforeRecording = _msgCtrl.text.trim();
      final ok = QrScannerHelper.startSpeechToText(
        onResult: (transcription) {
          if (!mounted) return;
          setState(() {
            if (_baseTextBeforeRecording.isEmpty) {
              _msgCtrl.text = transcription;
            } else {
              _msgCtrl.text = '$_baseTextBeforeRecording $transcription';
            }
            _msgCtrl.selection = TextSelection.fromPosition(TextPosition(offset: _msgCtrl.text.length));
          });
        },
        onEnd: () {
          if (mounted) {
            setState(() => _isRecording = false);
          }
        },
      );
      if (ok) {
        setState(() => _isRecording = true);
      }
    }
  }

  Future<void> _sendMessage() async {
    if (_isRecording) {
      QrScannerHelper.stopSpeechToText();
      setState(() => _isRecording = false);
    }
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;

    _msgCtrl.clear();
    try {
      final msg = await QuizizzService.sendResearchDiscussion(
        widget.groupId,
        message: text,
        recipientId: _selectedRecipientId,
      );
      if (msg != null && mounted) {
        setState(() {
          // Avoid duplicate if socket already inserted
          if (!_discussions.any((d) => d['id'] == msg['id'])) {
            _discussions.add(msg);
          }
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengirim pesan: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final currentUserId = auth.user?['id']?.toString() ?? '';
    final isDosen = auth.role == 'dosen';

    final mediaQuery = MediaQuery.of(context);
    final isMobile = mediaQuery.size.width < 600;

    // Filter discussions based on active tab (Broadcast vs Private Message)
    final filtered = _discussions.where((d) {
      if (_selectedRecipientId == null) {
        return d['recipient_id'] == null;
      } else {
        return (d['sender_id'] == _selectedRecipientId && d['recipient_id'] == currentUserId) ||
            (d['sender_id'] == currentUserId && d['recipient_id'] == _selectedRecipientId);
      }
    }).toList();

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _kNavyDark, width: 2),
      ),
      insetPadding: EdgeInsets.symmetric(horizontal: isMobile ? 8 : 24, vertical: isMobile ? 12 : 24),
      child: Container(
        width: isMobile ? double.infinity : 680,
        height: isMobile ? mediaQuery.size.height * 0.92 : 640,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            // HEADER CHAT
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: const BoxDecoration(
                color: _kNavyDark,
                borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _kMustardYellow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.forum_rounded, color: _kNavyDark, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '💬 Ruang Diskusi — ${widget.groupName}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // CHANNEL SELECTOR: GRUP VS PESAN PRIBADI
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: const Color(0xFFF1F5F9),
              child: Row(
                children: [
                  const Text('Saluran:', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black54)),
                  const SizedBox(width: 8),
                  ChoiceChip(
                    label: const Text('👥 Diskusi Grup'),
                    selected: _selectedRecipientId == null,
                    selectedColor: _kMustardYellow,
                    backgroundColor: Colors.white,
                    labelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _selectedRecipientId == null ? _kNavyDark : Colors.black54,
                    ),
                    onSelected: (_) => setState(() => _selectedRecipientId = null),
                  ),
                  const SizedBox(width: 6),

                  // Private Message options
                  if (isDosen) ...[
                    // Dosen can choose student for Private Message
                    PopupMenuButton<String>(
                      tooltip: 'Pilih Mahasiswa untuk Pesan Pribadi',
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: _selectedRecipientId != null ? _kMustardYellow : Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: _kNavyDark, width: 1),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.person_rounded, size: 14, color: _selectedRecipientId != null ? _kNavyDark : Colors.black54),
                            const SizedBox(width: 4),
                            Text(
                              _selectedRecipientId != null
                                  ? 'Pribadi: ${widget.members.firstWhere((m) => m['student_id'] == _selectedRecipientId, orElse: () => {'student_name': 'Mahasiswa'})['student_name']}'
                                  : '👤 Pesan Pribadi Mahasiswa...',
                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: _kNavyDark),
                            ),
                          ],
                        ),
                      ),
                      itemBuilder: (_) => widget.members.map((m) {
                        return PopupMenuItem<String>(
                          value: m['student_id']?.toString(),
                          child: Text('${m['student_name']} (${m['nim']})', style: const TextStyle(fontSize: 12)),
                        );
                      }).toList(),
                      onSelected: (val) => setState(() => _selectedRecipientId = val),
                    ),
                  ] else ...[
                    // Mahasiswa can send Private Message to Dosen
                    ChoiceChip(
                      label: const Text('👤 Pesan Pribadi ke Dosen'),
                      selected: _selectedRecipientId != null,
                      selectedColor: _kMustardYellow,
                      backgroundColor: Colors.white,
                      labelStyle: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _selectedRecipientId != null ? _kNavyDark : Colors.black54,
                      ),
                      onSelected: (_) => setState(() => _selectedRecipientId = widget.dosenId),
                    ),
                  ],
                ],
              ),
            ),

            // CHAT BODY
            Expanded(
              child: Container(
                color: const Color(0xFFF8FAFC),
                padding: const EdgeInsets.all(14),
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: _kNavyDark))
                    : (filtered.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(Icons.chat_bubble_outline_rounded, size: 40, color: Colors.black26),
                                const SizedBox(height: 8),
                                Text(
                                  _selectedRecipientId == null
                                      ? 'Belum ada pesan di diskusi grup ini.\nMulai percakapan dengan tim & dosen!'
                                      : 'Belum ada pesan pribadi.',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 12, color: Colors.black45),
                                ),
                              ],
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollCtrl,
                            itemCount: filtered.length,
                            itemBuilder: (ctx, idx) {
                              final d = filtered[idx];
                              final isMe = d['sender_id'] == currentUserId;
                              final isDosenMsg = d['sender_role'] == 'dosen';

                              return Align(
                                alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                child: Container(
                                  margin: const EdgeInsets.symmetric(vertical: 4),
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.45),
                                  decoration: BoxDecoration(
                                    color: isMe
                                        ? const Color(0xFFDCF8C6) // WhatsApp green for sent
                                        : Colors.white,
                                    borderRadius: BorderRadius.only(
                                      topLeft: const Radius.circular(14),
                                      topRight: const Radius.circular(14),
                                      bottomLeft: isMe ? const Radius.circular(14) : const Radius.circular(2),
                                      bottomRight: isMe ? const Radius.circular(2) : const Radius.circular(14),
                                    ),
                                    border: Border.all(color: _kNavyDark.withOpacity(0.3), width: 1),
                                    boxShadow: [
                                      BoxShadow(color: Colors.black.withOpacity(0.04), offset: const Offset(1, 1), blurRadius: 2),
                                    ],
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      if (!isMe) ...[
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              (d['sender_full_name'] != null && d['sender_full_name'].toString().trim().isNotEmpty)
                                                  ? d['sender_full_name'].toString().trim()
                                                  : (d['sender_name'] != null && d['sender_name'].toString().trim().isNotEmpty && d['sender_name'].toString().toLowerCase() != 'user')
                                                      ? d['sender_name'].toString().trim()
                                                      : (isDosenMsg ? 'Dosen' : 'Mahasiswa'),
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 11,
                                                color: isDosenMsg ? const Color(0xFF001D39) : const Color(0xFF0D9488),
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: isDosenMsg ? _kMustardYellow : const Color(0xFFE0E7FF),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                isDosenMsg ? 'DOSEN' : 'MHS',
                                                style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: _kNavyDark),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                      ],
                                      SelectableText(
                                        d['message'] ?? '',
                                        style: const TextStyle(fontSize: 13, color: Colors.black87),
                                      ),
                                      const SizedBox(height: 4),
                                      Align(
                                        alignment: Alignment.bottomRight,
                                        child: Text(
                                          d['created_at'] != null
                                              ? DateTime.parse(d['created_at']).toLocal().toString().substring(11, 16)
                                              : '',
                                          style: const TextStyle(fontSize: 9, color: Colors.black45),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          )),
              ),
            ),

            // INPUT BAR
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(bottomLeft: Radius.circular(18), bottomRight: Radius.circular(18)),
                border: Border(top: BorderSide(color: Colors.black12)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      decoration: InputDecoration(
                        hintText: _selectedRecipientId == null
                            ? 'Ketik pesan untuk seluruh grup...'
                            : 'Ketik pesan pribadi...',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: const BorderSide(color: _kNavyDark),
                        ),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        filled: true,
                        fillColor: const Color(0xFFF8FAFC),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (isDosen) ...[
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: _isRecording ? Colors.red.shade600 : const Color(0xFFF1F5F9),
                        shape: BoxShape.circle,
                        border: Border.all(color: _isRecording ? Colors.red.shade800 : _kNavyDark, width: 1.2),
                      ),
                      child: IconButton(
                        icon: Icon(
                          _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                          color: _isRecording ? Colors.white : _kNavyDark,
                          size: 20,
                        ),
                        tooltip: _isRecording ? 'Hentikan Rekam Suara' : 'Bicara (Speech to Text)',
                        onPressed: _toggleSpeech,
                      ),
                    ),
                  ],
                  Container(
                    decoration: const BoxDecoration(
                      color: _kNavyDark,
                      shape: BoxShape.circle,
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================================
// DIALOG DISKUSI SELURUH KELAS & PRIVATE MESSAGING (JAPRI ALA WHATSAPP)
// ============================================================================
class ClassDiscussionDialog extends StatefulWidget {
  final String classId;
  final String className;
  final String? subject;
  final String? dosenId;

  const ClassDiscussionDialog({
    super.key,
    required this.classId,
    required this.className,
    this.subject,
    this.dosenId,
  });

  @override
  State<ClassDiscussionDialog> createState() => _ClassDiscussionDialogState();
}

class _ClassDiscussionDialogState extends State<ClassDiscussionDialog> {
  bool _loadingContacts = true;
  bool _loadingDiscussions = false;
  bool _sending = false;
  bool _isRecording = false;
  String _baseTextBeforeRecording = '';

  Map<String, dynamic>? _dosen;
  List<Map<String, dynamic>> _students = [];
  int _classForumUnread = 0;

  // null = 'general' (Forum Seluruh Kelas), otherwise peer_id for Private Message
  String? _activePeerId;
  Map<String, dynamic>? _activePeer;

  String _searchQuery = '';
  List<Map<String, dynamic>> _discussions = [];

  final TextEditingController _msgCtrl = TextEditingController();
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  Timer? _pollTimer;
  bool _mobileShowChat = false;

  @override
  void initState() {
    super.initState();
    _loadContacts();
    _loadDiscussions();
    _setupSocket();
    // Auto-refresh every 3.5 seconds
    _pollTimer = Timer.periodic(const Duration(milliseconds: 3500), (_) {
      _loadContacts(silent: true);
      _loadDiscussions(silent: true);
    });
  }

  @override
  void dispose() {
    if (_isRecording) {
      QrScannerHelper.stopSpeechToText();
    }
    _pollTimer?.cancel();
    _msgCtrl.dispose();
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _setupSocket() {
    try {
      final socket = SocketService.socket;
      if (socket != null) {
        socket.on('class_chat_message', (data) {
          if (!mounted || data == null) return;
          final msg = Map<String, dynamic>.from(data);
          if (msg['class_id'] == widget.classId) {
            final isForumMsg = msg['recipient_id'] == null;
            final isCurrentForum = _activePeerId == null;
            final isCurrentPm = _activePeerId != null &&
                (msg['sender_id'] == _activePeerId || msg['recipient_id'] == _activePeerId);

            if ((isForumMsg && isCurrentForum) || (!isForumMsg && isCurrentPm)) {
              setState(() {
                if (!_discussions.any((d) => d['id'] == msg['id'])) {
                  _discussions.add(msg);
                }
              });
              _scrollToBottom();
              _markRead();
            } else {
              _loadContacts(silent: true);
            }
          }
        });

        socket.on('class_chat_notification', (_) {
          if (mounted) _loadContacts(silent: true);
        });
      }
    } catch (_) {}
  }

  Future<void> _loadContacts({bool silent = false}) async {
    if (!silent) setState(() => _loadingContacts = true);
    final data = await QuizizzService.getClassChatContacts(widget.classId);
    if (!mounted) return;
    setState(() {
      _dosen = data['dosen'] as Map<String, dynamic>?;
      _students = (data['students'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      _classForumUnread = data['class_forum_unread'] ?? 0;
      _loadingContacts = false;
    });
  }

  Future<void> _loadDiscussions({bool silent = false}) async {
    if (!silent) setState(() => _loadingDiscussions = true);
    final list = await QuizizzService.getClassDiscussions(widget.classId, peerId: _activePeerId);
    if (!mounted) return;
    setState(() {
      _discussions = list;
      _loadingDiscussions = false;
    });
    if (!silent) _scrollToBottom();
    _markRead();
  }

  Future<void> _markRead() async {
    await QuizizzService.markClassDiscussionRead(widget.classId, peerId: _activePeerId);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _toggleSpeech() {
    if (_isRecording) {
      QrScannerHelper.stopSpeechToText();
      setState(() => _isRecording = false);
    } else {
      _baseTextBeforeRecording = _msgCtrl.text.trim();
      final ok = QrScannerHelper.startSpeechToText(
        onResult: (transcription) {
          if (!mounted) return;
          setState(() {
            if (_baseTextBeforeRecording.isEmpty) {
              _msgCtrl.text = transcription;
            } else {
              _msgCtrl.text = '$_baseTextBeforeRecording $transcription';
            }
            _msgCtrl.selection = TextSelection.fromPosition(TextPosition(offset: _msgCtrl.text.length));
          });
        },
        onEnd: () {
          if (mounted) {
            setState(() => _isRecording = false);
          }
        },
      );
      if (ok) {
        setState(() => _isRecording = true);
      }
    }
  }

  Future<void> _sendMessage() async {
    if (_isRecording) {
      QrScannerHelper.stopSpeechToText();
      setState(() => _isRecording = false);
    }
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    _msgCtrl.clear();
    setState(() => _sending = true);
    try {
      final msg = await QuizizzService.sendClassDiscussion(
        widget.classId,
        message: text,
        recipientId: _activePeerId,
      );
      if (msg != null && mounted) {
        setState(() {
          if (!_discussions.any((d) => d['id'] == msg['id'])) {
            _discussions.add(msg);
          }
        });
        _scrollToBottom();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Gagal mengirim pesan: $e')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _selectPeer(String? peerId, [Map<String, dynamic>? peerData]) {
    setState(() {
      _activePeerId = peerId;
      _activePeer = peerData;
      _mobileShowChat = true;
    });
    _loadDiscussions();
  }

  @override
  Widget build(BuildContext context) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final currentUserId = auth.user?['id']?.toString() ?? '';
    final mediaQuery = MediaQuery.of(context);
    final isMobile = mediaQuery.size.width < 700;

    final filteredStudents = _students.where((s) {
      if (s['is_current_user'] == true) return false;
      if (_searchQuery.isEmpty) return true;
      final name = (s['full_name'] ?? '').toString().toLowerCase();
      final nim = (s['nim'] ?? '').toString().toLowerCase();
      final grp = (s['group_name'] ?? '').toString().toLowerCase();
      final q = _searchQuery.toLowerCase();
      return name.contains(q) || nim.contains(q) || grp.contains(q);
    }).toList();

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _kNavyDark, width: 2),
      ),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isMobile ? 8 : 24,
        vertical: isMobile ? 12 : 24,
      ),
      child: Container(
        width: isMobile ? double.infinity : 920,
        height: isMobile ? mediaQuery.size.height * 0.95 : 680,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            // TOP HEADER
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: const BoxDecoration(
                color: _kNavyDark,
                borderRadius: BorderRadius.only(topLeft: Radius.circular(18), topRight: Radius.circular(18)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _kMustardYellow,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.forum_rounded, color: _kNavyDark, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '💬 Ruang Diskusi & Pesan Pribadi — ${widget.className}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        Text(
                          'Mata Kuliah / Riset: ${widget.subject ?? 'Capstone Design'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                    tooltip: 'Tutup',
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // BODY: DUAL PANE OR MOBILE VIEW
            Expanded(
              child: isMobile
                  ? (_mobileShowChat ? _buildChatPane(currentUserId, isMobile: true) : _buildContactsPane(filteredStudents, currentUserId))
                  : Row(
                      children: [
                        SizedBox(
                          width: 300,
                          child: _buildContactsPane(filteredStudents, currentUserId),
                        ),
                        const VerticalDivider(width: 1, color: Colors.black12),
                        Expanded(
                          child: _buildChatPane(currentUserId, isMobile: false),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  // PANE 1: CONTACTS & CHANNELS LIST
  Widget _buildContactsPane(List<Map<String, dynamic>> filteredStudents, String currentUserId) {
    return Container(
      color: const Color(0xFFF8FAFC),
      child: Column(
        children: [
          // SEARCH BAR
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Cari mahasiswa / grup...',
                prefixIcon: const Icon(Icons.search_rounded, size: 18, color: Colors.black45),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Colors.black26),
                ),
                filled: true,
                fillColor: Colors.white,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              onChanged: (val) => setState(() => _searchQuery = val.trim()),
            ),
          ),

          Expanded(
            child: _loadingContacts
                ? const Center(child: CircularProgressIndicator(color: _kNavyDark))
                : ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    children: [
                      // 1. FORUM DISKUSI SELURUH KELAS
                      _buildChannelItem(
                        title: '📢 Forum Seluruh Kelas',
                        subtitle: 'Diskusi publik semua mahasiswa & dosen',
                  isSelected: _activePeerId == null,
                  unreadCount: _classForumUnread,
                  avatarBg: const Color(0xFF059669),
                  icon: Icons.groups_rounded,
                  onTap: () => _selectPeer(null),
                ),
                const SizedBox(height: 10),

                // 2. DOSEN PEMBIMBING (JAPRI)
                if (_dosen != null && _dosen!['id'] != currentUserId) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Text(
                      'Dosen Pembimbing',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black45),
                    ),
                  ),
                  _buildContactCard(
                    id: _dosen!['id'],
                    name: _dosen!['full_name'] ?? 'Dosen',
                    subtitle: 'Dosen Pembimbing / Kelas',
                    role: 'dosen',
                    avatarUrl: _dosen!['avatar_url'],
                    unreadCount: _dosen!['unread_count'] ?? 0,
                    isSelected: _activePeerId == _dosen!['id'],
                    onTap: () => _selectPeer(_dosen!['id'], _dosen),
                  ),
                  const SizedBox(height: 10),
                ],

                // 3. DAFTAR MAHASISWA SEKELAS (JAPRI)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(
                    'Mahasiswa di Kelas (${filteredStudents.length})',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black45),
                  ),
                ),
                if (filteredStudents.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Center(
                      child: Text('Tidak ada mahasiswa ditemukan.', style: TextStyle(fontSize: 12, color: Colors.black45)),
                    ),
                  )
                else
                  ...filteredStudents.map((s) {
                    final subtitle = s['group_name'] != null
                        ? 'NIM: ${s['nim'] ?? '-'} • ${s['group_name']}'
                        : 'NIM: ${s['nim'] ?? '-'}';
                    return _buildContactCard(
                      id: s['id'],
                      name: s['full_name'] ?? 'Mahasiswa',
                      subtitle: subtitle,
                      role: 'mahasiswa',
                      avatarUrl: s['avatar_url'],
                      unreadCount: s['unread_count'] ?? 0,
                      isSelected: _activePeerId == s['id'],
                      onTap: () => _selectPeer(s['id'], s),
                    );
                  }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelItem({
    required String title,
    required String subtitle,
    required bool isSelected,
    required int unreadCount,
    required Color avatarBg,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFE0F2FE) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? _kNavyDark : Colors.black12,
          width: isSelected ? 1.8 : 1,
        ),
      ),
      child: ListTile(
        dense: true,
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: CircleAvatar(
          backgroundColor: avatarBg,
          radius: 18,
          child: Icon(icon, color: Colors.white, size: 18),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 12,
            color: isSelected ? _kNavyDark : Colors.black87,
          ),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Colors.black54),
        ),
        trailing: unreadCount > 0
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$unreadCount',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              )
            : null,
      ),
    );
  }

  Widget _buildContactCard({
    required String id,
    required String name,
    required String subtitle,
    required String role,
    String? avatarUrl,
    required int unreadCount,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    final isDosen = role == 'dosen';
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFFE0F2FE) : Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelected ? _kNavyDark : Colors.black12,
          width: isSelected ? 1.8 : 1,
        ),
      ),
      child: ListTile(
        dense: true,
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        leading: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              backgroundColor: isDosen ? _kNavyDark : const Color(0xFF0D9488),
              radius: 18,
              backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty) ? NetworkImage(ApiService.getFullMediaUrl(avatarUrl)!) : null,
              child: (avatarUrl == null || avatarUrl.isEmpty)
                  ? Text(
                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    )
                  : null,
            ),
            if (isDosen)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: const BoxDecoration(color: Color(0xFFF59E0B), shape: BoxShape.circle),
                  child: const Icon(Icons.star_rounded, size: 10, color: Colors.white),
                ),
              ),
          ],
        ),
        title: Row(
          children: [
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                  color: isSelected ? _kNavyDark : Colors.black87,
                ),
              ),
            ),
          ],
        ),
        subtitle: Text(
          subtitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 10, color: Colors.black54),
        ),
        trailing: unreadCount > 0
            ? Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.red,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$unreadCount',
                  style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                ),
              )
            : null,
      ),
    );
  }

  // PANE 2: ACTIVE CHAT CONVERSATION
  Widget _buildChatPane(String currentUserId, {required bool isMobile}) {
    final auth = Provider.of<AuthProvider>(context, listen: false);
    final isDosen = auth.role == 'dosen';
    final isForum = _activePeerId == null;
    final chatTitle = isForum
        ? '📢 Forum Seluruh Kelas'
        : (_activePeer?['full_name'] ?? 'Pesan Pribadi');
    final chatSubtitle = isForum
        ? 'Pesan terlihat oleh seluruh mahasiswa dan dosen di kelas'
        : (_activePeer?['role'] == 'dosen' ? 'Dosen Pembimbing' : 'NIM: ${_activePeer?['nim'] ?? '-'} • Pesan Pribadi');

    return Container(
      color: const Color(0xFFF1F5F9),
      child: Column(
        children: [
          // CHAT ACTIVE HEADER
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            color: Colors.white,
            child: Row(
              children: [
                if (isMobile)
                  IconButton(
                    icon: const Icon(Icons.arrow_back_rounded, color: _kNavyDark),
                    onPressed: () => setState(() => _mobileShowChat = false),
                  ),
                CircleAvatar(
                  backgroundColor: isForum
                      ? const Color(0xFF059669)
                      : (_activePeer?['role'] == 'dosen' ? _kNavyDark : const Color(0xFF0D9488)),
                  radius: 18,
                  child: Icon(
                    isForum ? Icons.groups_rounded : Icons.person_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              chatTitle,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!isForum && _activePeer?['role'] == 'dosen') ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: _kMustardYellow,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('DOSEN', style: TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: _kNavyDark)),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        chatSubtitle,
                        style: const TextStyle(fontSize: 10, color: Colors.black54),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh_rounded, size: 18, color: Colors.black45),
                  tooltip: 'Segarkan pesan',
                  onPressed: () => _loadDiscussions(silent: true),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.black12),

          // CHAT MESSAGES
          Expanded(
            child: _loadingDiscussions
                ? const Center(child: CircularProgressIndicator(color: _kNavyDark))
                : _discussions.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(isForum ? Icons.campaign_rounded : Icons.chat_bubble_outline_rounded, size: 48, color: Colors.black26),
                            const SizedBox(height: 10),
                            Text(
                              isForum
                                  ? 'Belum ada diskusi di forum kelas.\nMulai percakapan bersama rekan kelas Anda!'
                                  : 'Belum ada pesan pribadi dengan $chatTitle.\nKirim pesan pertama Anda!',
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 12, color: Colors.black45),
                            ),
                          ],
                        ),
                      )
                    : SelectionArea(
                        child: ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                          itemCount: _discussions.length,
                          itemBuilder: (ctx, idx) {
                            final d = _discussions[idx];
                            final isMe = d['sender_id']?.toString() == currentUserId;
                            final isDosenMsg = d['sender_role'] == 'dosen';

                            return Align(
                              alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.7),
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isMe ? const Color(0xFFDCFCE7) : Colors.white,
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(16),
                                    topRight: const Radius.circular(16),
                                    bottomLeft: Radius.circular(isMe ? 16 : 4),
                                    bottomRight: Radius.circular(isMe ? 4 : 16),
                                  ),
                                  border: Border.all(
                                    color: isMe ? const Color(0xFF86EFAC) : Colors.black12,
                                    width: 1,
                                  ),
                                  boxShadow: const [
                                    BoxShadow(color: Colors.black12, offset: Offset(1, 1), blurRadius: 2),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (!isMe) ...[
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            (d['sender_full_name'] != null && d['sender_full_name'].toString().trim().isNotEmpty)
                                                ? d['sender_full_name'].toString().trim()
                                                : (d['sender_name'] != null && d['sender_name'].toString().trim().isNotEmpty && d['sender_name'].toString().toLowerCase() != 'user')
                                                    ? d['sender_name'].toString().trim()
                                                    : (isDosenMsg ? 'Dosen' : 'Mahasiswa'),
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 11,
                                              color: isDosenMsg ? const Color(0xFF001D39) : const Color(0xFF0D9488),
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                            decoration: BoxDecoration(
                                              color: isDosenMsg ? _kMustardYellow : const Color(0xFFE0E7FF),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              isDosenMsg ? 'DOSEN' : 'MHS',
                                              style: const TextStyle(fontSize: 8, fontWeight: FontWeight.bold, color: _kNavyDark),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                    ],
                                    SelectableText(
                                      d['message'] ?? '',
                                      style: const TextStyle(fontSize: 13, color: Colors.black87),
                                    ),
                                    const SizedBox(height: 4),
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: Text(
                                        d['created_at'] != null
                                            ? DateTime.parse(d['created_at']).toLocal().toString().substring(11, 16)
                                            : '',
                                        style: const TextStyle(fontSize: 9, color: Colors.black45),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),

          // CHAT INPUT BAR
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: Colors.white,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgCtrl,
                    maxLines: 3,
                    minLines: 1,
                    decoration: InputDecoration(
                      hintText: isForum ? 'Ketik pesan ke seluruh kelas...' : 'Ketik pesan pribadi...',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: const BorderSide(color: _kNavyDark),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      filled: true,
                      fillColor: const Color(0xFFF8FAFC),
                    ),
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                if (isDosen) ...[
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: _isRecording ? Colors.red.shade600 : const Color(0xFFF1F5F9),
                      shape: BoxShape.circle,
                      border: Border.all(color: _isRecording ? Colors.red.shade800 : _kNavyDark, width: 1.2),
                    ),
                    child: IconButton(
                      icon: Icon(
                        _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                        color: _isRecording ? Colors.white : _kNavyDark,
                        size: 20,
                      ),
                      tooltip: _isRecording ? 'Hentikan Rekam Suara' : 'Bicara (Speech to Text)',
                      onPressed: _toggleSpeech,
                    ),
                  ),
                ],
                Container(
                  decoration: const BoxDecoration(
                    color: _kNavyDark,
                    shape: BoxShape.circle,
                  ),
                  child: IconButton(
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    onPressed: _sendMessage,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
