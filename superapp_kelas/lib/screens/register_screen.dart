import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/classly_logo.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _nameController = TextEditingController();
  final _nimController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  String _selectedRole = 'mahasiswa';
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  Future<void> _handleRegister() async {
    // FITUR "Konfirmasi Password" (khusus form Mahasiswa): pastikan
    // Password & Konfirmasi Password sama sebelum kirim ke server.
    if (_selectedRole == 'mahasiswa' && _passwordController.text != _confirmPasswordController.text) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password dan Konfirmasi Password tidak sama')),
      );
      return;
    }
    if (_selectedRole == 'mahasiswa' && _nimController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('NIM wajib diisi')),
      );
      return;
    }

    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.register(
      _nameController.text.trim(),
      _emailController.text.trim(),
      _passwordController.text,
      _selectedRole,
      nim: _selectedRole == 'mahasiswa' ? _nimController.text.trim() : null,
    );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Registrasi berhasil! Silakan login, lalu lengkapi profil Anda.')),
      );
      Navigator.of(context).pop();
    } else if (mounted && authProvider.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(authProvider.errorMessage!)),
      );
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nimController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFFBDD8E9),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        foregroundColor: const Color(0xFF001D39),
      ),
      body: Stack(
        children: [
          Positioned(
            top: -50,
            left: -50,
            child: Container(
              width: 220,
              height: 220,
              decoration: const BoxDecoration(
                color: Color(0xFF7BBDE8),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  padding: const EdgeInsets.all(36),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: const Color(0xFF001D39), width: 2),
                    boxShadow: const [
                      BoxShadow(color: Color(0xFF001D39), offset: Offset(4, 4), blurRadius: 0),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // FITUR "Rebranding Classly": logo di atas judul,
                      // konsisten dengan halaman login.
                      const Center(child: ClasslyLogo(size: 64)),
                      const SizedBox(height: 14),
                      Text(
                        'REGISTRASI AKUN BARU',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, letterSpacing: 1.2, color: Color(0xFF001D39)),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'Bergabung dengan Ekosistem Classly Academic',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 24),
                      // FITUR "Form Registrasi Berbeda per Peran" (poin 2 & 3):
                      // pemilihan peran dipindah ke ATAS (sebelum field-field
                      // lain), supaya field yang tampil bisa langsung
                      // menyesuaikan -- Mahasiswa dapat field NIM & Konfirmasi
                      // Password tambahan, Dosen tidak.
                      const Text('Daftar sebagai:', style: TextStyle(fontWeight: FontWeight.w900, color: Color(0xFF001D39), fontSize: 13)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedRole = 'mahasiswa'),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: _selectedRole == 'mahasiswa' ? const Color(0xFF7BBDE8) : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0xFF001D39), width: 1.5),
                                ),
                                child: Column(
                                  children: [
                                    const Icon(Icons.school_rounded, color: Color(0xFF001D39), size: 24),
                                    const SizedBox(height: 4),
                                    Text('Mahasiswa', style: TextStyle(fontWeight: FontWeight.w900, color: const Color(0xFF001D39))),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedRole = 'dosen'),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: _selectedRole == 'dosen' ? const Color(0xFF7BBDE8) : Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: const Color(0xFF001D39), width: 1.5),
                                ),
                                child: Column(
                                  children: [
                                    const Icon(Icons.workspace_premium_rounded, color: Color(0xFF001D39), size: 24),
                                    const SizedBox(height: 4),
                                    Text('Dosen', style: TextStyle(fontWeight: FontWeight.w900, color: const Color(0xFF001D39))),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _nameController,
                        style: const TextStyle(color: Color(0xFF001D39), fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          labelText: 'Nama Lengkap',
                          labelStyle: const TextStyle(color: Colors.black54),
                          prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF001D39)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF001D39), width: 1.5)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF7BBDE8), width: 2.5)),
                          filled: true,
                          fillColor: const Color(0xFFBDD8E9),
                        ),
                      ),
                      // FITUR "NIM Saat Registrasi Mahasiswa" (poin 3): hanya
                      // tampil untuk peran Mahasiswa, sesuai form "Create
                      // Student Account".
                      if (_selectedRole == 'mahasiswa') ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: _nimController,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Color(0xFF001D39), fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            labelText: 'NIM',
                            labelStyle: const TextStyle(color: Colors.black54),
                            prefixIcon: const Icon(Icons.badge_outlined, color: Color(0xFF001D39)),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF001D39), width: 1.5)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF7BBDE8), width: 2.5)),
                            filled: true,
                            fillColor: const Color(0xFFBDD8E9),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        controller: _emailController,
                        style: const TextStyle(color: Color(0xFF001D39), fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          // FITUR "Email Institusi" (poin 2 & 3): label
                          // diseragamkan jadi "Email Institusi" untuk kedua
                          // peran, sesuai desain form yang diminta.
                          labelText: 'Email Institusi',
                          labelStyle: const TextStyle(color: Colors.black54),
                          prefixIcon: const Icon(Icons.email_outlined, color: Color(0xFF001D39)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF001D39), width: 1.5)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF7BBDE8), width: 2.5)),
                          filled: true,
                          fillColor: const Color(0xFFBDD8E9),
                        ),
                        keyboardType: TextInputType.emailAddress,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        style: const TextStyle(color: Color(0xFF001D39), fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          labelStyle: const TextStyle(color: Colors.black54),
                          prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF001D39)),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF001D39)),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF001D39), width: 1.5)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF7BBDE8), width: 2.5)),
                          filled: true,
                          fillColor: const Color(0xFFBDD8E9),
                        ),
                      ),
                      // FITUR "Konfirmasi Password" (poin 3): khusus form
                      // Mahasiswa, sesuai form "Create Student Account".
                      if (_selectedRole == 'mahasiswa') ...[
                        const SizedBox(height: 16),
                        TextField(
                          controller: _confirmPasswordController,
                          obscureText: _obscureConfirmPassword,
                          style: const TextStyle(color: Color(0xFF001D39), fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            labelText: 'Konfirmasi Password',
                            labelStyle: const TextStyle(color: Colors.black54),
                            prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF001D39)),
                            suffixIcon: IconButton(
                              icon: Icon(_obscureConfirmPassword ? Icons.visibility_off : Icons.visibility, color: const Color(0xFF001D39)),
                              onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                            ),
                            enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF001D39), width: 1.5)),
                            focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF7BBDE8), width: 2.5)),
                            filled: true,
                            fillColor: const Color(0xFFBDD8E9),
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: authProvider.isLoading ? null : _handleRegister,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF001D39),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: const BorderSide(color: Color(0xFF001D39), width: 1.5),
                            ),
                          ),
                          child: authProvider.isLoading
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                              // FITUR "Buat Akun" (poin 2 & 3): teks tombol
                              // diseragamkan jadi "Buat Akun" sesuai desain.
                              : const Text('✨ Buat Akun', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                        ),
                      ),
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
}