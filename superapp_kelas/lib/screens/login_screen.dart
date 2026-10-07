import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import 'register_screen.dart';
import 'class/class_screen.dart';
import '../widgets/doodle_pattern_background.dart';
import '../widgets/classly_logo.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _obscurePassword = true;

  Future<void> _handleLogin() async {
    final authProvider = context.read<AuthProvider>();
    final success = await authProvider.login(
      _emailController.text.trim(),
      _passwordController.text,
    );

    if (success && mounted) {
      // PENTING: login berhasil -> LANGSUNG ke Manajemen Kelas (bukan
      // dashboard modul umum lagi), baik untuk dosen maupun mahasiswa.
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const ClassDashboardScreen()),
      );
    } else if (mounted && authProvider.errorMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(authProvider.errorMessage!),
          backgroundColor: Colors.red.shade800,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.watch<AuthProvider>();

    return Scaffold(
      backgroundColor: const Color(0xFFBDD8E9),
      body: Stack(
        children: [
          // FITUR "Pattern Dekoratif Doodle Edukasi": lapisan latar halus
          // meniru gaya sketsa tangan bertema sekolah dari gambar referensi.
          const Positioned.fill(child: DoodlePatternBackground(color: Color(0xFF001D39))),
          // ABSTRACT RETRO SHAPES
          Positioned(
            top: -50,
            right: -50,
            child: Container(
              width: 220,
              height: 220,
              decoration: const BoxDecoration(
                color: Color(0xFF7BBDE8),
                shape: BoxShape.circle,
              ),
            ),
          ),
          Positioned(
            bottom: -60,
            left: -40,
            child: Container(
              width: 200,
              height: 200,
              decoration: BoxDecoration(
                color: const Color(0xFF7BBDE8).withValues(alpha: 0.3),
                shape: BoxShape.circle,
              ),
            ),
          ),

          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
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
                      // FITUR "Rebranding Classly": logo Classly (ikon
                      // bola lampu-otak dalam huruf "C") ditampilkan di
                      // atas judul, menggantikan ikon placeholder lama.
                      const Center(child: ClasslyLogo(size: 88)),
                      const SizedBox(height: 16),
                      Text(
                        'CLASSLY',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900, letterSpacing: 1.5, color: Color(0xFF001D39)),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Ide Cerdas, Kelas Terkoneksi',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.black54, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      SizedBox(height: 28),
                      TextField(
                        controller: _emailController,
                        style: const TextStyle(color: Color(0xFF001D39), fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          labelText: 'Email Akademik / NIM',
                          hintText: 'Masukkan Email atau NIM Anda',
                          labelStyle: const TextStyle(color: Colors.black54),
                          prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF001D39)),
                          enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF001D39), width: 1.5)),
                          focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: const BorderSide(color: Color(0xFF7BBDE8), width: 2.5)),
                          filled: true,
                          fillColor: const Color(0xFFBDD8E9),
                        ),
                        keyboardType: TextInputType.text,
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
                      const SizedBox(height: 24),
                      SizedBox(
                        height: 48,
                        child: ElevatedButton(
                          onPressed: authProvider.isLoading ? null : _handleLogin,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF001D39),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(24),
                              side: const BorderSide(color: Color(0xFF001D39), width: 1.5),
                            ),
                          ),
                          child: authProvider.isLoading
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                                )
                              : const Text('🚀 Masuk Portal', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const RegisterScreen()),
                          );
                        },
                        child: const Text('Belum punya akun? Registrasi Akun Akademik', style: TextStyle(color: Color(0xFF001D39), fontSize: 13, fontWeight: FontWeight.w800)),
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