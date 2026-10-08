const express = require('express');
const router = express.Router();
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const multer = require('multer');
const path = require('path');
const { v4: uuidv4 } = require('uuid');
const pool = require('../db');
const { verifyToken } = require('../middleware/auth');

const fs = require('fs');

// The supplied SQL export does not contain the application's base schema.
// Keep this bootstrap idempotent so a clean local database can be started
// without a separate migration step.
async function initUsersTable() {
  await pool.query(`
    CREATE TABLE IF NOT EXISTS users (
      id VARCHAR(64) PRIMARY KEY,
      full_name VARCHAR(255) NOT NULL,
      email VARCHAR(255) NOT NULL UNIQUE,
      password_hash VARCHAR(255) NOT NULL,
      role ENUM('dosen', 'mahasiswa') NOT NULL,
      avatar_url VARCHAR(255) DEFAULT NULL,
      created_at DATETIME DEFAULT CURRENT_TIMESTAMP
    )
  `);
}

initUsersTable().catch((error) => {
  console.error('Users table init info:', error.message);
});

// ============ Konfigurasi upload avatar (folder uploads/avatars) ============
const avatarDir = path.join(__dirname, '..', 'uploads', 'avatars');
if (!fs.existsSync(avatarDir)) {
  fs.mkdirSync(avatarDir, { recursive: true });
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, 'uploads/avatars/'),
  filename: (req, file, cb) => {
    const uniqueName = `avatar-${Date.now()}-${uuidv4()}${path.extname(file.originalname)}`;
    cb(null, uniqueName);
  },
});
const upload = multer({
  storage,
  limits: { fileSize: 5 * 1024 * 1024 }, // maks 5MB untuk avatar
});

// FITUR "Lengkapi Profil Dosen/Mahasiswa": kolom tambahan di tabel users
// untuk data profil akademik. Dijalankan sekali saat server start (aman
// dipanggil berulang berkat try/catch per kolom, sama seperti pola
// migrasi ringan yang dipakai di routes/quizizz.js).
(async () => {
  await initUsersTable();
  const cols = [
    ['nidn_nip', 'VARCHAR(50)'],       // Dosen: NIDN/NIP
    ['nim', 'VARCHAR(50)'],            // Mahasiswa: NIM
    ['fakultas', 'VARCHAR(255)'],      // Dosen & Mahasiswa
    ['program_studi', 'VARCHAR(255)'], // Dosen & Mahasiswa
    ['angkatan', 'VARCHAR(10)'],       // Mahasiswa
    ['nomor_hp', 'VARCHAR(30)'],       // Dosen & Mahasiswa
  ];
  for (const [name, type] of cols) {
    try { await pool.query(`ALTER TABLE users ADD COLUMN ${name} ${type}`); } catch (_) {}
  }
})();

// ============ REGISTER ============
router.post('/register', async (req, res) => {
  try {
    const fullName = req.body.full_name || req.body.name;
    const { email, password, role } = req.body;
    // FITUR "Registrasi Akun Mahasiswa Pakai NIM": NIM diisi langsung saat
    // registrasi (bukan di langkah lengkapi profil setelah login), sesuai
    // form "Create Student Account". Untuk dosen, NIM tidak dipakai.
    const nim = req.body.nim ? req.body.nim.toString().trim() : null;

    if (!fullName || !email || !password || !role) {
      return res.status(400).json({
        status: 'gagal',
        message: 'full_name / name, email, password, dan role wajib diisi',
      });
    }

    if (!['dosen', 'mahasiswa'].includes(role)) {
      return res.status(400).json({
        status: 'gagal',
        message: "role harus 'dosen' atau 'mahasiswa'",
      });
    }

    if (role === 'mahasiswa' && !nim) {
      return res.status(400).json({
        status: 'gagal',
        message: 'NIM wajib diisi untuk registrasi akun Mahasiswa',
      });
    }

    const [existing] = await pool.query('SELECT id FROM users WHERE email = ?', [email]);
    if (existing.length > 0) {
      return res.status(409).json({
        status: 'gagal',
        message: 'Email sudah terdaftar',
      });
    }

    const password_hash = await bcrypt.hash(password, 10);
    const id = uuidv4();

    await pool.query(
      'INSERT INTO users (id, full_name, email, password_hash, role, nim) VALUES (?, ?, ?, ?, ?, ?)',
      [id, fullName, email, password_hash, role, nim]
    );

    res.status(201).json({
      status: 'sukses',
      message: 'Registrasi berhasil',
      user: { id, name: fullName, full_name: fullName, email, role, nim },
    });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ LOGIN ============
router.post('/login', async (req, res) => {
  try {
    const { email, password } = req.body;

    if (!email || !password) {
      return res.status(400).json({
        status: 'gagal',
        message: 'email dan password wajib diisi',
      });
    }

    const identifier = String(email).trim();
    const [rows] = await pool.query(
      'SELECT * FROM users WHERE email = ? OR nim = ? OR email LIKE CONCAT(?, \'@%\')',
      [identifier, identifier, identifier]
    );
    if (rows.length === 0) {
      return res.status(401).json({ status: 'gagal', message: 'Email/NIM atau password salah' });
    }

    const user = rows[0];
    const isMatch = await bcrypt.compare(password, user.password_hash);
    if (!isMatch) {
      return res.status(401).json({ status: 'gagal', message: 'Email/NIM atau password salah' });
    }

    const token = jwt.sign(
      { id: user.id, role: user.role, name: user.full_name, full_name: user.full_name, nim: user.nim },
      process.env.JWT_SECRET,
      { expiresIn: '7d' }
    );

    res.json({
      status: 'sukses',
      message: 'Login berhasil',
      token,
      user: {
        id: user.id,
        name: user.full_name,
        full_name: user.full_name,
        email: user.email,
        role: user.role,
        avatar_url: user.avatar_url,
        signature_url: user.signature_url,
        nidn_nip: user.nidn_nip,
        nim: user.nim,
        fakultas: user.fakultas,
        program_studi: user.program_studi,
        angkatan: user.angkatan,
        nomor_hp: user.nomor_hp,
      },
    });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ LENGKAPI / EDIT PROFIL (butuh login) ============
router.put('/profile', verifyToken, async (req, res) => {
  try {
    const allowedFields = ['full_name', 'nidn_nip', 'nim', 'fakultas', 'program_studi', 'angkatan', 'nomor_hp'];
    const updates = [];
    const values = [];
    for (const field of allowedFields) {
      if (req.body[field] !== undefined) {
        updates.push(`${field} = ?`);
        values.push(req.body[field] === '' ? null : req.body[field]);
      }
    }
    if (updates.length === 0) {
      return res.status(400).json({ status: 'gagal', message: 'Tidak ada field yang dikirim untuk diperbarui' });
    }
    values.push(req.user.id);
    await pool.query(`UPDATE users SET ${updates.join(', ')} WHERE id = ?`, values);

    const [rows] = await pool.query(
      'SELECT id, full_name, email, role, avatar_url, signature_url, nidn_nip, nim, fakultas, program_studi, angkatan, nomor_hp FROM users WHERE id = ?',
      [req.user.id]
    );
    res.json({ status: 'sukses', message: 'Profil berhasil diperbarui', user: rows[0] });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ UPLOAD / GANTI AVATAR (butuh login) ============
const handleAvatarUpload = async (req, res) => {
  try {
    let filename;
    if (req.file) {
      filename = req.file.filename;
    } else if (req.body && (req.body.image_base64 || req.body.avatar_base64 || req.body.file_base64)) {
      const rawBase64 = req.body.image_base64 || req.body.avatar_base64 || req.body.file_base64;
      const matches = rawBase64.match(/^data:([A-Za-z-+\/]+);base64,(.+)$/);
      let buffer;
      if (matches && matches.length === 3) {
        buffer = Buffer.from(matches[2], 'base64');
      } else {
        buffer = Buffer.from(rawBase64, 'base64');
      }
      filename = `avatar-${Date.now()}-${uuidv4()}.png`;
      fs.writeFileSync(path.join(avatarDir, filename), buffer);
    } else {
      return res.status(400).json({ status: 'gagal', message: 'File tidak ditemukan' });
    }

    const avatarUrl = `/uploads/avatars/${filename}`;
    if (req.user && req.user.id) {
      await pool.query('UPDATE users SET avatar_url = ? WHERE id = ?', [avatarUrl, req.user.id]);
    }

    res.json({
      status: 'sukses',
      message: 'Avatar berhasil diperbarui',
      avatar_url: avatarUrl,
    });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: error.message });
  }
};

const optionalUploadAvatar = (req, res, next) => {
  upload.single('file')(req, res, (err) => {
    next();
  });
};

router.post('/upload-avatar', verifyToken, optionalUploadAvatar, handleAvatarUpload);
router.post('/avatar', verifyToken, optionalUploadAvatar, handleAvatarUpload);

// ============ UPLOAD TANDA TANGAN DOSEN (PNG) ============
const signatureDir = path.join(__dirname, '..', 'uploads', 'signatures');
if (!fs.existsSync(signatureDir)) {
  fs.mkdirSync(signatureDir, { recursive: true });
}

const signatureStorage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, 'uploads/signatures/'),
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase() || '.png';
    const uniqueName = `sig-${Date.now()}-${uuidv4()}${ext}`;
    cb(null, uniqueName);
  },
});
const uploadSignature = multer({
  storage: signatureStorage,
  limits: { fileSize: 10 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    cb(null, true);
  },
});

const optionalUploadSignature = (req, res, next) => {
  uploadSignature.single('file')(req, res, (err) => {
    next();
  });
};

const handleSignatureUpload = async (req, res) => {
  try {
    let filename;
    if (req.file) {
      filename = req.file.filename;
    } else if (req.body && (req.body.image_base64 || req.body.signature_base64 || req.body.file_base64 || req.body.signature_data)) {
      const rawBase64 = req.body.image_base64 || req.body.signature_base64 || req.body.file_base64 || req.body.signature_data;
      const matches = rawBase64.match(/^data:([A-Za-z-+\/]+);base64,(.+)$/);
      let buffer;
      if (matches && matches.length === 3) {
        buffer = Buffer.from(matches[2], 'base64');
      } else {
        buffer = Buffer.from(rawBase64, 'base64');
      }
      filename = `sig-${Date.now()}-${uuidv4()}.png`;
      fs.writeFileSync(path.join(signatureDir, filename), buffer);
    } else {
      return res.status(400).json({ status: 'gagal', message: 'File gambar tanda tangan wajib diunggah' });
    }

    const signatureUrl = `/uploads/signatures/${filename}`;
    if (req.user && req.user.id) {
      await pool.query('UPDATE users SET signature_url = ? WHERE id = ?', [signatureUrl, req.user.id]);
    }

    res.json({
      status: 'sukses',
      message: 'Tanda tangan digital berhasil disimpan',
      signature_url: signatureUrl,
    });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.post('/signature', verifyToken, optionalUploadSignature, handleSignatureUpload);
router.post('/upload-signature', verifyToken, optionalUploadSignature, handleSignatureUpload);

module.exports = router;
