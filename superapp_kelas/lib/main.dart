import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/auth_provider.dart';
import 'screens/login_screen.dart';
import 'screens/class/class_screen.dart';

void main() {
  runApp(
    ChangeNotifierProvider(
      create: (_) => AuthProvider()..tryAutoLogin(),
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Classly',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFBDD8E9),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF7BBDE8),
          primary: const Color(0xFF7BBDE8),
          secondary: const Color(0xFF001D39),
          surface: const Color(0xFFFFFFFF),
        ),
        fontFamily: 'Roboto',
      ),
      home: Consumer<AuthProvider>(
        builder: (context, auth, _) {
          if (auth.isLoggedIn) {
            // PENTING: setelah login, dosen & mahasiswa LANGSUNG masuk ke
            // Manajemen Kelas (bukan dashboard modul umum lagi) -- mahasiswa
            // wajib pilih/join kelas dulu sebelum bisa akses konten apapun,
            // dan dosen langsung melihat daftar kelas yang ia kelola.
            return const ClassDashboardScreen();
          }
          return const LoginScreen();
        },
      ),
    );
  }
}