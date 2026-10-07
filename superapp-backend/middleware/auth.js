const jwt = require('jsonwebtoken');

// Middleware: cek apakah request punya token JWT yang valid
function verifyToken(req, res, next) {
  const authHeader = req.headers['authorization'];

  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({
      status: 'gagal',
      message: 'Token tidak ditemukan. Silakan login terlebih dahulu.',
    });
  }

  const token = authHeader.split(' ')[1];

  try {
    const decoded = jwt.verify(token, process.env.JWT_SECRET);
    // Simpan data user (id, role) ke req.user, biar bisa dipakai di route selanjutnya
    req.user = decoded;
    next();
  } catch (error) {
    return res.status(401).json({
      status: 'gagal',
      message: 'Token tidak valid atau sudah kedaluwarsa.',
    });
  }
}

// Middleware tambahan: cek apakah role user sesuai (misal cuma 'dosen' yang boleh)
function requireRole(...allowedRoles) {
  return (req, res, next) => {
    if (!req.user || !allowedRoles.includes(req.user.role)) {
      return res.status(403).json({
        status: 'gagal',
        message: 'Anda tidak punya izin untuk mengakses ini.',
      });
    }
    next();
  };
}

module.exports = { verifyToken, requireRole };
