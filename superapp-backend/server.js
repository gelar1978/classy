const express = require('express');
const cors = require('cors');
const http = require('http');
const { Server } = require('socket.io');
require('dotenv').config();
const pool = require('./db');
const authRoutes = require('./routes/auth');
const quizizzRoutes = require('./routes/quizizz');
const { verifyToken } = require('./middleware/auth');

const app = express();
const server = http.createServer(app);

const io = new Server(server, {
  cors: {
    origin: '*',
    methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization'],
  },
});

app.set('io', io);

io.on('connection', (socket) => {
  console.log('Socket client connected:', socket.id);

  socket.on('join_room', (room) => {
    if (room) {
      socket.join(room);
      socket.join(`session_${room}`);
    }
  });

  socket.on('join_session', (sessionId) => {
    if (sessionId) {
      socket.join(sessionId);
      socket.join(`session_${sessionId}`);
    }
  });

  socket.on('join', (ch) => {
    if (ch) {
      socket.join(ch);
      socket.join(`session_${ch}`);
    }
  });

  socket.on('pointer_update', (data) => {
    const room = data.room;
    if (room) {
      // Broadcast to both raw room and session_room formats to be safe
      socket.to(room).emit('pointer_update', data);
      socket.to(`session_${room}`).emit('pointer_update', data);
    }
  });
});

app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
}));
app.use(express.json({ limit: '500mb' }));
app.use(express.urlencoded({ limit: '500mb', extended: true }));

const path = require('path');
const fs = require('fs');

// Serving static uploads folder for uploaded images & avatars & documents
app.use('/uploads', express.static(path.join(__dirname, 'uploads')));
app.use('/api/uploads', express.static(path.join(__dirname, 'uploads')));

// Serving Flutter Web static build if present
const publicDir = path.join(__dirname, 'public');
if (fs.existsSync(publicDir)) {
  app.use(express.static(publicDir));
}

app.get('/api/test-db', async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT COUNT(*) AS total_tabel FROM information_schema.tables WHERE table_schema = ?',
      [process.env.DB_NAME]
    );
    res.json({
      status: 'sukses',
      message: 'Koneksi database berhasil!',
      total_tabel: rows[0].total_tabel,
    });
  } catch (error) {
    res.status(500).json({
      status: 'gagal',
      message: error.message,
    });
  }
});

app.use('/api/auth', authRoutes);
app.use('/api/quizizz', quizizzRoutes);

app.get('/api/auth/me', verifyToken, async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT id, full_name, email, role, avatar_url, signature_url, nidn_nip, nim, fakultas, program_studi, angkatan, nomor_hp, created_at FROM users WHERE id = ?',
      [req.user.id]
    );
    if (rows.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'User tidak ditemukan' });
    }
    res.json({ status: 'sukses', user: rows[0] });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// SPA fallback for Flutter web or root route
app.use((req, res) => {
  if (req.path.startsWith('/api') || req.path.startsWith('/uploads')) {
    return res.status(404).json({ status: 'gagal', message: 'Endpoint not found' });
  }
  const indexHtml = path.join(publicDir, 'index.html');
  if (fs.existsSync(indexHtml)) {
    return res.sendFile(indexHtml);
  }
  res.json({ message: 'Backend Superapp Academic (Quizizz) Running with Socket.io!' });
});

const PORT = process.env.PORT || 3000;

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`\n❌ Error: Port ${PORT} sedang digunakan oleh proses lain!`);
    console.error(`Untuk membebaskan port ${PORT}, jalankan perintah berikut di PowerShell:\n`);
    console.error(`Stop-Process -Id (Get-NetTCPConnection -LocalPort ${PORT}).OwningProcess -Force\n`);
  } else {
    console.error('Server error:', err);
  }
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`Server jalan di http://0.0.0.0:${PORT}`);
});
