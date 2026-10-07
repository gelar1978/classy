import 'dart:convert';
import 'package:flutter/foundation.dart';
import '../services/api_service.dart';

class AuthProvider extends ChangeNotifier {
  Map<String, dynamic>? _user;
  bool _isLoading = false;
  String? _errorMessage;

  Map<String, dynamic>? get user => _user;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;
  bool get isLoggedIn => _user != null;
  String? get role => _user?['role']?.toString();
  bool get isDosen => _user?['role'] == 'dosen';
  bool get isMahasiswa => _user?['role'] == 'mahasiswa';

  void updateUserLocal(Map<String, dynamic> data) {
    if (_user != null) {
      _user = {..._user!, ...data};
      notifyListeners();
    }
  }

  Future<void> tryAutoLogin() async {
    final token = await ApiService.getToken();
    if (token == null) return;

    try {
      final result = await ApiService.get('/auth/me');
      _user = result['user'];
      notifyListeners();
    } catch (e) {
      await ApiService.clearToken();
    }
  }

  Future<bool> login(String email, String password) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await ApiService.post(
        '/auth/login',
        {'email': email, 'password': password},
        withAuth: false,
      );
      await ApiService.saveToken(result['token']);
      _user = result['user'];
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> register(String fullName, String email, String password, String role, {String? nim}) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      await ApiService.post(
        '/auth/register',
        {
          'full_name': fullName,
          'email': email,
          'password': password,
          'role': role,
          if (nim != null && nim.isNotEmpty) 'nim': nim,
        },
        withAuth: false,
      );
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  // FITUR "Lengkapi Profil Dosen/Mahasiswa": kirim field yang mau
  // diperbarui (nidn_nip/nim/fakultas/program_studi/angkatan/nomor_hp),
  // dipakai dari layar "Lengkapi Profil" setelah login.
  Future<bool> updateProfile(Map<String, dynamic> fields) async {
    _isLoading = true;
    _errorMessage = null;
    notifyListeners();

    try {
      final result = await ApiService.put('/auth/profile', fields);
      if (result['user'] != null) {
        _user = {...?_user, ...Map<String, dynamic>.from(result['user'])};
      }
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<void> logout() async {
    await ApiService.clearToken();
    _user = null;
    notifyListeners();
  }

  Future<bool> uploadAvatar(List<int> fileBytes, String filename) async {
    try {
      final base64String = base64Encode(fileBytes);
      final result = await ApiService.post('/auth/avatar', {
        'image_base64': base64String,
        'filename': filename,
      });
      if (_user != null) {
        _user!['avatar_url'] = result['avatar_url'];
      }
      notifyListeners();
      return true;
    } catch (e) {
      _errorMessage = e.toString().replaceAll('Exception: ', '');
      notifyListeners();
      return false;
    }
  }
}