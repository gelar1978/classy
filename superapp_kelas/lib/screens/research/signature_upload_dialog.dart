import 'dart:async';
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/api_service.dart';
import '../../services/quizizz_service.dart';

const Color _kNavyDark = Color(0xFF001D39);
const Color _kMustardYellow = Color(0xFF7BBDE8);

class SignatureUploadDialog extends StatefulWidget {
  const SignatureUploadDialog({super.key});

  static Future<void> show(BuildContext context) async {
    await showDialog(
      context: context,
      builder: (_) => const SignatureUploadDialog(),
    );
  }

  @override
  State<SignatureUploadDialog> createState() => _SignatureUploadDialogState();
}

class _SignatureUploadDialogState extends State<SignatureUploadDialog> {
  bool _uploading = false;
  String? _currentSignatureUrl;
  Uint8List? _previewBytes;
  String? _selectedFileName;
  StreamSubscription? _pasteSub;

  @override
  void initState() {
    super.initState();
    final auth = Provider.of<AuthProvider>(context, listen: false);
    _currentSignatureUrl = auth.user?['signature_url']?.toString();
    _setupClipboardPasteListener();
  }

  @override
  void dispose() {
    _pasteSub?.cancel();
    super.dispose();
  }

  void _setupClipboardPasteListener() {
    if (kIsWeb) {
      try {
        _pasteSub = html.document.onPaste.listen((html.Event e) {
          final clipboardEvent = e as html.ClipboardEvent;
          final items = clipboardEvent.clipboardData?.items;
          if (items != null) {
            final length = items.length ?? 0;
            for (int i = 0; i < length; i++) {
              final item = items[i];
              if (item.type != null && item.type!.startsWith('image/')) {
                final blob = item.getAsFile();
                if (blob != null) {
                  final reader = html.FileReader();
                  reader.readAsArrayBuffer(blob);
                  reader.onLoadEnd.listen((_) {
                    if (reader.result != null && mounted) {
                      setState(() {
                        _previewBytes = Uint8List.fromList(reader.result as List<int>);
                        _selectedFileName = 'pasted_ttd_${DateTime.now().millisecondsSinceEpoch}.png';
                      });
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('✅ Gambar tanda tangan berhasil ditempel dari clipboard!'),
                          backgroundColor: Color(0xFF059669),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    }
                  });
                  break;
                }
              }
            }
          }
        });
      } catch (_) {}
    }
  }

  Future<void> _pasteFromClipboard() async {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('💡 Silakan tekan Ctrl+V (atau Cmd+V di Mac) untuk menempelkan gambar tanda tangan dari clipboard.'),
          backgroundColor: _kNavyDark,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _pickSignatureFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg'],
        withData: true,
      );
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.bytes != null) {
          setState(() {
            _previewBytes = file.bytes;
            _selectedFileName = file.name;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memilih file: $e')),
        );
      }
    }
  }

  Future<void> _saveSignature() async {
    if (_previewBytes == null) return;
    setState(() => _uploading = true);

    try {
      final uploadedUrl = await QuizizzService.uploadSignature(
        _previewBytes!,
        _selectedFileName ?? 'ttd.png',
      );

      if (mounted) {
        final auth = Provider.of<AuthProvider>(context, listen: false);
        if (auth.user != null && uploadedUrl != null) {
          final updatedUser = Map<String, dynamic>.from(auth.user!);
          updatedUser['signature_url'] = uploadedUrl;
          auth.updateUserLocal(updatedUser);
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Tanda tangan digital berhasil disimpan!'),
            backgroundColor: Color(0xFF059669),
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Gagal mengunggah tanda tangan: $e'),
            backgroundColor: Colors.red.shade700,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 500;

    final hasExistingSig = _currentSignatureUrl != null && _currentSignatureUrl!.isNotEmpty;
    final String? fullExistingUrl = hasExistingSig
        ? (_currentSignatureUrl!.startsWith('http')
            ? _currentSignatureUrl
            : '${ApiService.baseUrl.replaceAll('/api', '')}$_currentSignatureUrl')
        : null;

    return Dialog(
      backgroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: _kNavyDark, width: 2),
      ),
      insetPadding: EdgeInsets.symmetric(horizontal: isMobile ? 12 : 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(isMobile ? 16 : 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // TITLE BAR
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: _kMustardYellow,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _kNavyDark, width: 1.5),
                    ),
                    child: const Icon(Icons.draw_rounded, color: _kNavyDark, size: 20),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '🖋️ Tanda Tangan Digital Dosen',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: _kNavyDark),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded, color: Colors.black54, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // INFO BOX
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFEF3C7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFD97706), width: 1),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline_rounded, color: Color(0xFFB45309), size: 18),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Tanda tangan ini akan otomatis ditempelkan pada dokumen PDF yang Anda setujui (Approve). Anda dapat mengunggah file gambar (.PNG) atau menempelkan (Ctrl+V) langsung dari clipboard.',
                        style: TextStyle(fontSize: 11, color: Color(0xFF78350F), height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              const Text(
                'Pratinjau / Kotak Tanda Tangan:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: _kNavyDark),
              ),
              const SizedBox(height: 8),

              // DROP / PASTE BOX
              InkWell(
                onTap: _pasteFromClipboard,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  width: double.infinity,
                  height: 150,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _previewBytes != null ? const Color(0xFF059669) : _kNavyDark, width: 1.8),
                  ),
                  child: Stack(
                    children: [
                      Center(
                        child: _previewBytes != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Image.memory(_previewBytes!, fit: BoxFit.contain),
                                ),
                              )
                            : (fullExistingUrl != null
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Image.network(
                                        fullExistingUrl,
                                        fit: BoxFit.contain,
                                        errorBuilder: (ctx, err, stack) => const Center(
                                          child: Text('Gagal memuat gambar TTD', style: TextStyle(color: Colors.black45, fontSize: 12)),
                                        ),
                                      ),
                                    ),
                                  )
                                : const Center(
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Icon(Icons.gesture_rounded, size: 36, color: Colors.black26),
                                        SizedBox(height: 6),
                                        Text(
                                          'Belum ada tanda tangan',
                                          style: TextStyle(fontSize: 12, color: Colors.black45, fontWeight: FontWeight.bold),
                                        ),
                                        SizedBox(height: 2),
                                        Text(
                                          'Tekan Ctrl+V untuk Paste atau pilih file',
                                          style: TextStyle(fontSize: 10, color: Colors.black38),
                                        ),
                                      ],
                                    ),
                                  )),
                      ),
                      if (_previewBytes != null)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFF059669),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Gambar Baru Dipilih', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // ACTION BUTTONS TO PICK OR PASTE
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _pickSignatureFile,
                    icon: const Icon(Icons.upload_file_rounded, size: 16),
                    label: const Text('Pilih File PNG/JPG', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kNavyDark,
                      side: const BorderSide(color: _kNavyDark, width: 1.5),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                  ElevatedButton.icon(
                    onPressed: _pasteFromClipboard,
                    icon: const Icon(Icons.content_paste_rounded, size: 16),
                    label: const Text('Tempel Clipboard (Ctrl+V)', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFEFF6FF),
                      foregroundColor: const Color(0xFF1D4ED8),
                      elevation: 0,
                      side: const BorderSide(color: Color(0xFF93C5FD), width: 1.2),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // BOTTOM ACTION BUTTONS
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Batal', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 8),
                  if (_previewBytes != null)
                    ElevatedButton(
                      onPressed: _uploading ? null : _saveSignature,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _kNavyDark,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                      ),
                      child: _uploading
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Text('Simpan Tanda Tangan', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
