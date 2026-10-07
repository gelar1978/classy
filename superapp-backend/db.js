const mysql = require('mysql2/promise');
require('dotenv').config();

const pool = mysql.createPool({
  host: process.env.DB_HOST,
  user: process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  database: process.env.DB_NAME,
  port: process.env.DB_PORT,
  waitForConnections: true,
  connectionLimit: 10,
  queueLimit: 0,
  enableKeepAlive: true,
  keepAliveInitialDelay: 10000,
  // PENTING: paksa semua kolom DATETIME dibaca/ditulis sebagai UTC ('Z'),
  // bukan mengikuti timezone lokal server. Tanpa ini, tenggat waktu PR
  // (dan field waktu lain) bisa bergeser beberapa jam saat dibaca ulang
  // oleh mahasiswa di zona waktu yang berbeda dari server backend.
  timezone: 'Z',
});

module.exports = pool;
