const express = require('express');
const router = express.Router();
const { v4: uuidv4 } = require('uuid');
const pool = require('../db');
const { verifyToken } = require('../middleware/auth');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const AdmZip = require('adm-zip');
const { PDFDocument, rgb, StandardFonts } = require('pdf-lib');

// Multer khusus upload file .pptx (disimpan di memori saja, tidak ditulis
// ke disk -- hanya dibaca sesaat untuk diekstrak gambarnya lalu dibuang).
const pptxUpload = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: 30 * 1024 * 1024 }, // maks 30MB per file PPT
});

// Setup directory upload gambar soal (folder uploads/questions)
const questionImgDir = path.join(__dirname, '..', 'uploads', 'questions');
if (!fs.existsSync(questionImgDir)) {
  fs.mkdirSync(questionImgDir, { recursive: true });
}

// Setup directory upload dokumen riset (folder uploads/documents)
const docDir = path.join(__dirname, '..', 'uploads', 'documents');
if (!fs.existsSync(docDir)) {
  fs.mkdirSync(docDir, { recursive: true });
}

const docStorage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, 'uploads/documents/'),
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname).toLowerCase() || '.pdf';
    const uniqueName = `doc-${Date.now()}-${uuidv4()}${ext}`;
    cb(null, uniqueName);
  },
});

const uploadDoc = multer({
  storage: docStorage,
  limits: { fileSize: 25 * 1024 * 1024 }, // maks 25MB
});

const questionImgStorage = multer.diskStorage({
  destination: (req, file, cb) => cb(null, 'uploads/questions/'),
  filename: (req, file, cb) => {
    const ext = path.extname(file.originalname) || '.png';
    const uniqueName = `question-${Date.now()}-${uuidv4()}${ext}`;
    cb(null, uniqueName);
  },
});

const uploadQuestionImg = multer({
  storage: questionImgStorage,
  limits: { fileSize: 5 * 1024 * 1024 }, // Maksimal 5MB (memenuhi syarat > 2MB)
});

function generatePin() {
  return String(Math.floor(100000 + Math.random() * 900000));
}

// Inisialisasi Otomatis Tabel Quizizz
async function initQuizizzTables() {
  try {
    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_quizzes (
        id VARCHAR(64) PRIMARY KEY,
        user_id VARCHAR(64) NOT NULL,
        title VARCHAR(255) NOT NULL,
        description TEXT,
        quiz_type VARCHAR(50) DEFAULT 'quiz',
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    try { await pool.query(`ALTER TABLE quizizz_quizzes ADD COLUMN quiz_type VARCHAR(50) DEFAULT 'quiz'`); } catch (_) {}
    // PENTING (fitur "Manajemen Kelas"): setiap kuis boleh terhubung ke SATU
    // kelas (class_id). Kuis lama (dibuat sebelum fitur ini ada) akan
    // punya class_id NULL — tetap ditampilkan sebagai "Kuis Umum" (di luar
    // kelas manapun) supaya tidak hilang, tapi kuis BARU yang dibuat dari
    // dalam sebuah kelas WAJIB diisi class_id, sehingga kuis Kelas A tidak
    // akan pernah muncul di Kelas B walau dibuat dosen yang sama.
    try { await pool.query(`ALTER TABLE quizizz_quizzes ADD COLUMN class_id VARCHAR(64) DEFAULT NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE research_groups ADD COLUMN dosen_pembimbing_1 VARCHAR(255) NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE research_groups ADD COLUMN dosen_pembimbing_2 VARCHAR(255) NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE research_groups ADD COLUMN dosen_kelas VARCHAR(255) NULL`); } catch (_) {}

    // ----------------------------------------------------------------------
    // TABEL "MANAJEMEN KELAS": setiap kelas dibuat oleh SATU dosen, punya
    // token unik untuk di-share ke mahasiswa (mirip kode kelas Google
    // Classroom). Mahasiswa join sekali lewat token, keanggotaan tersimpan
    // permanen di quizizz_class_members (tidak perlu input token ulang
    // setiap login).
    // ----------------------------------------------------------------------
    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_classes (
        id VARCHAR(64) PRIMARY KEY,
        dosen_id VARCHAR(64) NOT NULL,
        class_name VARCHAR(255) NOT NULL,
        subject VARCHAR(255) NOT NULL,
        token VARCHAR(20) NOT NULL UNIQUE,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_class_members (
        id VARCHAR(64) PRIMARY KEY,
        class_id VARCHAR(64) NOT NULL,
        student_id VARCHAR(64) NOT NULL,
        student_name VARCHAR(255),
        joined_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        UNIQUE KEY uniq_class_student (class_id, student_id)
      )
    `);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_questions (
        id VARCHAR(64) PRIMARY KEY,
        quiz_id VARCHAR(64) NOT NULL,
        question_text TEXT NOT NULL,
        question_type VARCHAR(50) DEFAULT 'multiple_choice',
        option_a VARCHAR(255),
        option_b VARCHAR(255),
        option_c VARCHAR(255),
        option_d VARCHAR(255),
        options_json TEXT,
        correct_answer VARCHAR(255),
        image_url VARCHAR(255),
        order_index INT DEFAULT 0
      )
    `);
    try { await pool.query(`ALTER TABLE quizizz_questions ADD COLUMN question_type VARCHAR(50) DEFAULT 'multiple_choice'`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions ADD COLUMN options_json TEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions MODIFY COLUMN option_a VARCHAR(255) NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions MODIFY COLUMN option_b VARCHAR(255) NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions MODIFY COLUMN option_c VARCHAR(255) NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions MODIFY COLUMN option_d VARCHAR(255) NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions MODIFY COLUMN image_url LONGTEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions MODIFY COLUMN correct_answer TEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions ADD COLUMN timer_seconds INT DEFAULT 30`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions ADD COLUMN correct_list_json TEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_questions DROP FOREIGN KEY quizizz_questions_ibfk_1`); } catch (_) {}
    // FITUR "Gambar di Jawaban PG" (poin 5): gambar opsional per-opsi
    // jawaban (Pilihan Ganda & Multi-Select) untuk Kuis Gamifikasi & PR,
    // disimpan sebagai JSON array base64 data URL sejajar index dengan
    // opsi (options_json / option_a..d).
    try { await pool.query(`ALTER TABLE quizizz_questions ADD COLUMN option_images_json LONGTEXT`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_game_sessions (
        id VARCHAR(64) PRIMARY KEY,
        quiz_id VARCHAR(64) NOT NULL,
        host_id VARCHAR(64) NOT NULL,
        pin VARCHAR(20) NOT NULL,
        mode VARCHAR(50) DEFAULT 'live',
        deadline DATETIME NULL,
        status VARCHAR(50) DEFAULT 'waiting',
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    try { await pool.query(`ALTER TABLE quizizz_game_sessions ADD COLUMN mode VARCHAR(50) DEFAULT 'live'`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_game_sessions ADD COLUMN deadline DATETIME NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_game_sessions MODIFY COLUMN status VARCHAR(50) DEFAULT 'waiting'`); } catch (_) {}
    // Kolom started_at: menyimpan SATU waktu server yang sama untuk semua
    // mahasiswa, diisi persis sekali saat dosen menekan "Mulai Room Game
    // Sekarang" (status -> active). Dipakai supaya timer soal SAMA PERSIS
    // untuk semua mahasiswa (dihitung dari titik waktu server ini), bukan
    // dihitung ulang dari kapan masing-masing perangkat mahasiswa membuka
    // layar soal (yang bisa berbeda-beda tergantung kecepatan jaringan).
    try { await pool.query(`ALTER TABLE quizizz_game_sessions ADD COLUMN started_at DATETIME NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_game_sessions ADD COLUMN shuffle_questions TINYINT(1) DEFAULT 0`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_game_sessions ADD COLUMN shuffle_answers TINYINT(1) DEFAULT 0`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_session_players (
        id VARCHAR(64) PRIMARY KEY,
        session_id VARCHAR(64) NOT NULL,
        user_id VARCHAR(64) NULL,
        display_name VARCHAR(100) NOT NULL,
        score INT DEFAULT 0,
        completed TINYINT DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    try { await pool.query(`ALTER TABLE quizizz_session_players ADD COLUMN user_id VARCHAR(64) NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_session_players ADD COLUMN completed TINYINT DEFAULT 0`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_session_players ADD COLUMN created_at DATETIME DEFAULT CURRENT_TIMESTAMP`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_question_answers (
        id VARCHAR(64) PRIMARY KEY,
        session_id VARCHAR(64) NOT NULL,
        question_id VARCHAR(64) NOT NULL,
        player_id VARCHAR(64) NOT NULL,
        answer_text TEXT,
        is_correct TINYINT DEFAULT 0,
        answered_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    try { await pool.query(`ALTER TABLE quizizz_question_answers ADD COLUMN answer_text TEXT`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_lessons (
        id VARCHAR(64) PRIMARY KEY,
        dosen_id VARCHAR(64) NOT NULL,
        title VARCHAR(255) NOT NULL,
        description TEXT,
        slides_json TEXT NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    // PENTING: slides_json HARUS LONGTEXT, bukan TEXT biasa (batas ~65KB).
    // Slide presentasi bisa berisi banyak gambar base64 (termasuk hasil
    // ekstrak file .pptx) yang mudah melebihi 65KB -- kalau memakai TEXT,
    // data terpotong diam-diam saat disimpan sehingga penyimpanan gagal /
    // presentasi "menghilang".
    try { await pool.query(`ALTER TABLE quizizz_lessons MODIFY COLUMN slides_json LONGTEXT NOT NULL`); } catch (_) {}
    // Fitur "Manajemen Kelas": presentasi juga bisa terikat ke kelas
    // tertentu (nullable untuk presentasi lama sebelum fitur ini ada).
    try { await pool.query(`ALTER TABLE quizizz_lessons ADD COLUMN class_id VARCHAR(64) DEFAULT NULL`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_lesson_sessions (
        id VARCHAR(64) PRIMARY KEY,
        lesson_id VARCHAR(64) NOT NULL,
        session_code VARCHAR(10) NOT NULL,
        active_slide_index INT DEFAULT 0,
        status VARCHAR(20) DEFAULT 'live',
        responses_json TEXT,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    // PENTING: responses_json juga bisa menampung banyak jawaban mahasiswa
    // seiring waktu -- naikkan ke LONGTEXT supaya tidak terpotong pada sesi
    // presentasi yang ramai/panjang.
    try { await pool.query(`ALTER TABLE quizizz_lesson_sessions MODIFY COLUMN responses_json LONGTEXT`); } catch (_) {}

    // ------------------------------------------------------------------
    // FITUR "KELOLA SOAL PRESENTASI" (poin 2) + "TANYA-JAWAB LIVE" (poin 3)
    // ------------------------------------------------------------------
    // Bank soal milik SATU presentasi (lesson), dibuat terpisah dari slide
    // -- dosen bisa buat banyak soal dulu, baru pilih & "aktifkan" salah
    // satu soal kapanpun saat presentasi sedang berlangsung (mirip
    // Mentimeter/Kahoot yang digabung dengan slide materi).
    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_lesson_questions (
        id VARCHAR(64) PRIMARY KEY,
        lesson_id VARCHAR(64) NOT NULL,
        question_text TEXT NOT NULL,
        options_json TEXT,
        correct_answer VARCHAR(255),
        order_index INT DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    // Fitur "Tipe Soal Presentasi": pilihan ganda (default), benar/salah,
    // atau jawaban singkat -- menentukan opsi apa yang ditampilkan ke
    // mahasiswa saat soal diaktifkan.
    try { await pool.query(`ALTER TABLE quizizz_lesson_questions ADD COLUMN question_type VARCHAR(30) DEFAULT 'multiple_choice'`); } catch (_) {}
    // Fitur "Timer Soal Presentasi": batas waktu (detik) menjawab soal ini
    // sejak diaktifkan. NULL = tanpa batas waktu.
    try { await pool.query(`ALTER TABLE quizizz_lesson_questions ADD COLUMN time_limit_seconds INT DEFAULT 30`); } catch (_) {}
    // FITUR "Gambar di Soal & Jawaban Presentasi" (poin 4): gambar untuk
    // pertanyaan itu sendiri (image_url), dan gambar terpisah untuk
    // masing-masing opsi jawaban (option_images_json, array sejajar index
    // dengan options_json -- null kalau opsi itu tidak punya gambar).
    // LONGTEXT dipakai (bukan TEXT biasa) karena gambar disimpan sebagai
    // base64 data URL yang bisa cukup besar.
    try { await pool.query(`ALTER TABLE quizizz_lesson_questions ADD COLUMN image_url LONGTEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_lesson_questions ADD COLUMN option_images_json LONGTEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_lesson_questions MODIFY COLUMN options_json LONGTEXT`); } catch (_) {}

    // Kolom tambahan pada sesi live presentasi:
    // - active_question_ids: DAFTAR (JSON array, maks 2) soal yang SEDANG
    //   diaktifkan dosen saat ini secara bersamaan. Mahasiswa otomatis
    //   melihat semua soal ini muncul & bisa langsung menjawab.
    // - question_activated_at_json: JSON object {question_id: ISO-timestamp}
    //   kapan tiap soal aktif diaktifkan -- dipakai menghitung timer mundur.
    // - activated_history_json: JSON array berisi SEMUA question_id yang
    //   PERNAH diaktifkan di sesi ini (dipakai indikator "Sudah Digunakan"
    //   di bank soal, walau soal itu sudah dinonaktifkan lagi).
    // - question_answers_json: kumpulan jawaban mahasiswa untuk soal yang
    //   sedang/pernah aktif di sesi ini (dipakai untuk skor live & riwayat).
    // - qa_messages_json: daftar pertanyaan bebas yang diajukan mahasiswa
    //   selama presentasi berlangsung (fitur tanya-jawab live).
    try { await pool.query(`ALTER TABLE quizizz_lesson_sessions ADD COLUMN active_question_id VARCHAR(64) DEFAULT NULL`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_lesson_sessions ADD COLUMN active_question_ids LONGTEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_lesson_sessions ADD COLUMN question_activated_at_json LONGTEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_lesson_sessions ADD COLUMN activated_history_json LONGTEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_lesson_sessions ADD COLUMN question_answers_json LONGTEXT`); } catch (_) {}
    try { await pool.query(`ALTER TABLE quizizz_lesson_sessions ADD COLUMN qa_messages_json LONGTEXT`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_flashcards (
        id VARCHAR(64) PRIMARY KEY,
        dosen_id VARCHAR(64),
        code VARCHAR(10) NOT NULL,
        title VARCHAR(255) NOT NULL,
        subject VARCHAR(100) DEFAULT 'Umum',
        cards_json LONGTEXT NOT NULL,
        is_public BOOLEAN DEFAULT TRUE,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    // PENTING: cards_json HARUS LONGTEXT, bukan TEXT biasa (batas ~65KB).
    // Kartu flashcard bisa menyimpan gambar base64 yang mudah melebihi
    // 65KB, dan kalau memakai TEXT datanya terpotong diam-diam saat
    // disimpan -- itulah sebabnya gambar tidak muncul di sisi mahasiswa.
    try { await pool.query(`ALTER TABLE quizizz_flashcards MODIFY COLUMN cards_json LONGTEXT NOT NULL`); } catch (_) {}
    // Fitur "Manajemen Kelas": flashcard juga bisa terikat ke kelas tertentu
    // (nullable untuk flashcard lama / flashcard publik lintas-kelas).
    try { await pool.query(`ALTER TABLE quizizz_flashcards ADD COLUMN class_id VARCHAR(64) DEFAULT NULL`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_flashcard_progress (
        id VARCHAR(64) PRIMARY KEY,
        flashcard_id VARCHAR(64) NOT NULL,
        student_id VARCHAR(64) NOT NULL,
        mastered_cards_json TEXT,
        review_needed_cards_json TEXT,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
      )
    `);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_homework (
        id VARCHAR(64) PRIMARY KEY,
        quiz_id VARCHAR(64) NOT NULL,
        dosen_id VARCHAR(64) NOT NULL,
        title VARCHAR(255) NOT NULL,
        description TEXT,
        deadline DATETIME NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS homework_assignments (
        id VARCHAR(64) PRIMARY KEY,
        quiz_id VARCHAR(64) NOT NULL,
        dosen_id VARCHAR(64),
        title VARCHAR(255) NOT NULL,
        description TEXT,
        deadline DATETIME NOT NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
      )
    `);
    // Kolom status untuk fitur "Nonaktifkan PR": PR yang dinonaktifkan dosen
    // TIDAK BOLEH lagi muncul di daftar PR aktif mahasiswa manapun (lintas
    // device), jadi status harus disimpan di backend, bukan cuma localStorage.
    try { await pool.query(`ALTER TABLE homework_assignments ADD COLUMN status VARCHAR(50) DEFAULT 'active'`); } catch (_) {}

    // --- PEMBERSIHAN DATA "HANTU" (ONE-TIME CLEANUP) ---
    // Bug lama pada POST /sessions membuat baris kuis palsu di quizizz_quizzes
    // (id = id sesi, judul fallback literal "Live Host Gamifikasi") setiap
    // kali dosen menekan "Mulai Live Host Gamifikasi" ATAU menugaskan PR.
    // Baris ini SELALU bisa dikenali persis: id-nya SAMA dengan id yang ada
    // di quizizz_sessions (kuis asli tidak pernah begitu), dan judulnya
    // persis "Live Host Gamifikasi". Aman dijalankan berkali-kali (idempotent).
    try {
      await pool.query(
        `DELETE FROM quizizz_quizzes WHERE title = 'Live Host Gamifikasi' AND id IN (SELECT id FROM quizizz_sessions)`
      );
    } catch (_) {}
    // Baris homework_assignments/quizizz_sessions "hantu" dengan judul fallback
    // yang sama juga dibersihkan (bukan PR sungguhan yang dibuat dosen).
    try {
      await pool.query(`DELETE FROM homework_assignments WHERE title = 'Live Host Gamifikasi'`);
    } catch (_) {}
    try {
      await pool.query(`DELETE FROM quizizz_sessions WHERE title = 'Live Host Gamifikasi' AND mode = 'homework'`);
    } catch (_) {}
    try {
      await pool.query(
        `DELETE FROM quizizz_game_sessions WHERE mode = 'homework' AND id NOT IN (SELECT id FROM quizizz_sessions) AND id NOT IN (SELECT id FROM homework_assignments)`
      );
    } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS homework_submissions (
        id VARCHAR(64) PRIMARY KEY,
        homework_id VARCHAR(64) NOT NULL,
        student_name VARCHAR(255) NOT NULL,
        student_id VARCHAR(64),
        score INT DEFAULT 0,
        total_questions INT DEFAULT 0,
        status VARCHAR(50) DEFAULT 'Selesai (Tepat Waktu)',
        submitted_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    // Kolom detail jawaban PER SOAL (fitur "Riwayat Jawaban PR"): menyimpan
    // JSON berisi tiap soal + jawaban mahasiswa + jawaban benar + status
    // benar/salah, supaya bisa ditampilkan ulang di halaman Riwayat baik
    // mahasiswa maupun dosen tanpa perlu menghitung ulang.
    try { await pool.query(`ALTER TABLE homework_submissions ADD COLUMN answers_json LONGTEXT`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_sessions (
        id VARCHAR(64) PRIMARY KEY,
        quiz_id VARCHAR(64) NOT NULL,
        host_id VARCHAR(64),
        mode VARCHAR(50) DEFAULT 'homework',
        title VARCHAR(255) NOT NULL,
        description TEXT,
        deadline DATETIME,
        status VARCHAR(50) DEFAULT 'active',
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
      )
    `);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_homework_submissions (
        id VARCHAR(64) PRIMARY KEY,
        session_id VARCHAR(64) NOT NULL,
        student_name VARCHAR(255) NOT NULL,
        student_id VARCHAR(64),
        score INT DEFAULT 0,
        total_questions INT DEFAULT 0,
        submitted_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);
    try { await pool.query(`ALTER TABLE quizizz_homework_submissions ADD COLUMN answers_json LONGTEXT`); } catch (_) {}

    await pool.query(`
      CREATE TABLE IF NOT EXISTS quizizz_live_sessions (
        id VARCHAR(64) PRIMARY KEY,
        quiz_id VARCHAR(64) NOT NULL,
        session_code VARCHAR(10) NOT NULL,
        status VARCHAR(20) DEFAULT 'waiting',
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);

    // ----------------------------------------------------------------------
    // TABEL GRADEBOOK & REKAP NILAI KELAS
    // ----------------------------------------------------------------------
    await pool.query(`
      CREATE TABLE IF NOT EXISTS class_assessments (
        id VARCHAR(64) PRIMARY KEY,
        class_id VARCHAR(64) NOT NULL,
        title VARCHAR(255) NOT NULL,
        type VARCHAR(50) DEFAULT 'quiz',
        max_score INT DEFAULT 100,
        quiz_id VARCHAR(64) NULL,
        homework_id VARCHAR(64) NULL,
        order_index INT DEFAULT 0,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP
      )
    `);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS class_student_grades (
        id VARCHAR(64) PRIMARY KEY,
        class_id VARCHAR(64) NOT NULL,
        assessment_id VARCHAR(64) NOT NULL,
        student_id VARCHAR(64) NOT NULL,
        nim VARCHAR(50) NOT NULL,
        score DECIMAL(5,2) NULL,
        notes VARCHAR(255) NULL,
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
        UNIQUE KEY uniq_assess_student (assessment_id, student_id)
      )
    `);

    // ----------------------------------------------------------------------
    // TABEL PRESENSI & ABSENSI QR CODE PEKAN KE-SEKIAN
    // ----------------------------------------------------------------------
    await pool.query(`
      CREATE TABLE IF NOT EXISTS class_attendance_sessions (
        id VARCHAR(64) PRIMARY KEY,
        class_id VARCHAR(64) NOT NULL,
        dosen_id VARCHAR(64) NOT NULL,
        week_number INT NOT NULL,
        title VARCHAR(255) NOT NULL,
        session_code VARCHAR(32) NOT NULL UNIQUE,
        qr_data VARCHAR(255) NOT NULL,
        status VARCHAR(20) DEFAULT 'open',
        opened_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        closed_at DATETIME NULL
      )
    `);

    await pool.query(`
      CREATE TABLE IF NOT EXISTS class_attendance_records (
        id VARCHAR(64) PRIMARY KEY,
        session_id VARCHAR(64) NOT NULL,
        class_id VARCHAR(64) NOT NULL,
        student_id VARCHAR(64) NOT NULL,
        nim VARCHAR(50) NOT NULL,
        student_name VARCHAR(255) NOT NULL,
        status VARCHAR(20) DEFAULT 'hadir',
        attended_at DATETIME DEFAULT CURRENT_TIMESTAMP,
        notes VARCHAR(255) NULL,
        UNIQUE KEY uniq_session_student (session_id, student_id)
      )
    `);

    try {
      await pool.query("DELETE FROM quizizz_sessions WHERE title LIKE '%Pengetahuan Umum%' OR title LIKE '%Gamifikasi%' OR title = 'PR Mandiri' OR id = '1'");
      await pool.query("DELETE FROM quizizz_game_sessions WHERE id = '1' OR mode = 'homework' AND (SELECT title FROM quizizz_quizzes WHERE id = quizizz_game_sessions.quiz_id) LIKE '%Pengetahuan Umum%'");
      await pool.query("DELETE FROM homework_assignments WHERE title LIKE '%Pengetahuan Umum%' OR title LIKE '%Gamifikasi%' OR title = 'PR Mandiri' OR id = '1'");
      await pool.query("DELETE FROM quizizz_homework WHERE title LIKE '%Pengetahuan Umum%' OR title LIKE '%Gamifikasi%' OR title = 'PR Mandiri' OR id = '1'");
      await pool.query("DELETE FROM quizizz_homework_submissions WHERE session_id = '1' OR student_name LIKE '%Dummy%'");
      await pool.query("DELETE FROM homework_submissions WHERE homework_id = '1' OR student_name LIKE '%Dummy%'");
    } catch (_) {}
  } catch (err) {
    console.error('Quizizz table init info:', err.message);
  }
}
initQuizizzTables();

// ============================================================================
// FITUR "MANAJEMEN KELAS" (Class Management)
// ============================================================================
// Menghasilkan token kelas unik: 6 karakter alfanumerik huruf besar (mirip
// kode kelas Google Classroom), mudah diketik ulang manual oleh mahasiswa.
function generateClassToken() {
  const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; // tanpa huruf/angka yang mirip (I,O,0,1)
  let token = '';
  for (let i = 0; i < 6; i++) token += chars[Math.floor(Math.random() * chars.length)];
  return token;
}

// 1. DOSEN: Buat kelas baru. Wajib isi nama kelas + mata kuliah. Token unik
//    dibuat otomatis (retry kalau kebetulan bentrok, walau sangat jarang).
//    Mendukung class_type: 'mata_kuliah' (default) atau 'riset'.
router.post('/classes', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'dosen') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya dosen yang dapat membuat kelas' });
    }
    const { class_name, subject } = req.body;
    const class_type = req.body.class_type === 'riset' ? 'riset' : 'mata_kuliah';

    if (!class_name || !subject) {
      return res.status(400).json({ status: 'gagal', message: 'Nama kelas dan mata kuliah wajib diisi' });
    }

    const id = uuidv4();
    let token = generateClassToken();
    for (let attempt = 0; attempt < 5; attempt++) {
      const [existing] = await pool.query('SELECT id FROM quizizz_classes WHERE token = ?', [token]);
      if (existing.length === 0) break;
      token = generateClassToken();
    }

    await pool.query(
      'INSERT INTO quizizz_classes (id, dosen_id, class_name, subject, token, class_type) VALUES (?, ?, ?, ?, ?, ?)',
      [id, String(req.user.id), class_name, subject, token, class_type]
    );

    res.status(201).json({
      status: 'sukses',
      message: 'Kelas berhasil dibuat',
      class: { id, class_name, subject, token, class_type, dosen_id: String(req.user.id), member_count: 0, quiz_count: 0 }
    });
  } catch (error) {
    console.error("CREATE CLASS ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 2. DOSEN: Daftar semua kelas milik dosen yang sedang login.
router.get('/classes/mine', verifyToken, async (req, res) => {
  try {
    const [classes] = await pool.query(
      `SELECT c.*,
              (SELECT COUNT(*) FROM quizizz_class_members m WHERE m.class_id = c.id) AS member_count,
              (SELECT COUNT(*) FROM quizizz_quizzes q WHERE q.class_id = c.id) AS quiz_count,
              (SELECT COUNT(*) FROM research_groups rg WHERE rg.class_id = c.id) AS group_count
       FROM quizizz_classes c
       WHERE c.dosen_id = ?
       ORDER BY c.created_at DESC`,
      [String(req.user.id)]
    );
    res.json({ status: 'success', classes });
  } catch (error) {
    console.error("GET MINE CLASSES ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 3. MAHASISWA: Join kelas memakai token kelas ATAU kode grup/QR riset.
//    Keanggotaan disimpan PERMANEN di quizizz_class_members dan research_group_members.
router.post('/classes/join', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'mahasiswa') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya mahasiswa yang dapat join kelas' });
    }

    let rawInput = (req.body.token || req.body.group_code || req.body.code || '').toString().trim();
    if (!rawInput) {
      return res.status(400).json({ status: 'gagal', message: 'Token kelas atau kode grup wajib diisi' });
    }

    // Jika input adalah JSON QR code (mis. {"app":"classly","type":"research_group","group_code":"..."})
    let parsedGroupCode = null;
    let parsedGroupId = null;
    if (rawInput.startsWith('{') && rawInput.endsWith('}')) {
      try {
        const qrJson = JSON.parse(rawInput);
        if (qrJson.group_code) parsedGroupCode = qrJson.group_code;
        if (qrJson.group_id) parsedGroupId = qrJson.group_id;
        if (qrJson.token) rawInput = qrJson.token;
      } catch (_) {}
    }

    // Update info profil mahasiswa jika dikirimkan nama/NIM
    const studentName = req.body.student_name || req.body.name || req.user.name || 'Mahasiswa';
    const studentNim = req.body.nim ? String(req.body.nim).trim() : (req.user.nim || null);
    if (studentNim || (studentName && studentName !== 'Mahasiswa')) {
      try {
        const upFields = [];
        const upVals = [];
        if (studentName && studentName !== 'Mahasiswa') { upFields.push('full_name = ?'); upVals.push(studentName); }
        if (studentNim) { upFields.push('nim = ?'); upVals.push(studentNim); }
        if (upFields.length > 0) {
          upVals.push(String(req.user.id));
          await pool.query(`UPDATE users SET ${upFields.join(', ')} WHERE id = ?`, upVals);
        }
      } catch (_) {}
    }

    // Cek apakah input adalah kode grup riset
    let targetGroup = null;
    let targetClass = null;

    if (parsedGroupId || parsedGroupCode || rawInput) {
      const searchCode = parsedGroupCode || rawInput.toUpperCase();
      const [grpRows] = await pool.query(
        'SELECT rg.*, c.class_name, c.subject, c.token as class_token, c.class_type FROM research_groups rg JOIN quizizz_classes c ON c.id = rg.class_id WHERE rg.group_code = ? OR rg.id = ?',
        [searchCode, parsedGroupId || rawInput]
      );
      if (grpRows.length > 0) {
        targetGroup = grpRows[0];
        targetClass = {
          id: targetGroup.class_id,
          class_name: targetGroup.class_name,
          subject: targetGroup.subject,
          token: targetGroup.class_token,
          class_type: targetGroup.class_type,
        };
      }
    }

    // Jika bukan kode grup, cek apakah token kelas biasa
    if (!targetClass) {
      const cleanToken = rawInput.toUpperCase();
      const [classes] = await pool.query('SELECT * FROM quizizz_classes WHERE token = ?', [cleanToken]);
      if (classes.length > 0) {
        targetClass = classes[0];
      }
    }

    if (!targetClass) {
      return res.status(404).json({ status: 'gagal', message: 'Kode kelas atau grup tidak ditemukan. Periksa kembali token dari dosen Anda.' });
    }

    // Masukkan mahasiswa ke quizizz_class_members jika belum ada
    const [existingMember] = await pool.query(
      'SELECT id FROM quizizz_class_members WHERE class_id = ? AND student_id = ?',
      [targetClass.id, String(req.user.id)]
    );
    if (existingMember.length === 0) {
      await pool.query(
        'INSERT INTO quizizz_class_members (id, class_id, student_id, student_name) VALUES (?, ?, ?, ?)',
        [uuidv4(), targetClass.id, String(req.user.id), studentName]
      );
    }

    // Jika join via grup riset, daftarkan juga ke research_group_members
    if (targetGroup) {
      const [existingGroupMember] = await pool.query(
        'SELECT id FROM research_group_members WHERE group_id = ? AND student_id = ?',
        [targetGroup.id, String(req.user.id)]
      );
      if (existingGroupMember.length === 0) {
        await pool.query(
          'INSERT INTO research_group_members (id, group_id, class_id, student_id, student_name, nim) VALUES (?, ?, ?, ?, ?, ?)',
          [uuidv4(), targetGroup.id, targetClass.id, String(req.user.id), studentName, studentNim]
        );
      }
    }

    res.status(200).json({
      status: 'sukses',
      message: targetGroup ? `Berhasil bergabung ke ${targetGroup.group_name} (${targetClass.class_name})` : 'Berhasil bergabung ke kelas',
      class: targetClass,
      group: targetGroup
    });
  } catch (error) {
    console.error("JOIN CLASS ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 4. MAHASISWA: Daftar kelas yang sudah pernah di-join (tampil otomatis di
//    dashboard, tanpa perlu input token ulang).
router.get('/classes/joined', verifyToken, async (req, res) => {
  try {
    const [classes] = await pool.query(
      `SELECT c.*, m.joined_at,
              (SELECT COUNT(*) FROM quizizz_quizzes q WHERE q.class_id = c.id) AS quiz_count,
              (SELECT rgm.group_id FROM research_group_members rgm WHERE rgm.class_id = c.id AND rgm.student_id = m.student_id LIMIT 1) AS my_group_id,
              (SELECT rg.group_name FROM research_group_members rgm JOIN research_groups rg ON rg.id = rgm.group_id WHERE rgm.class_id = c.id AND rgm.student_id = m.student_id LIMIT 1) AS my_group_name
       FROM quizizz_class_members m
       JOIN quizizz_classes c ON c.id = m.class_id
       WHERE m.student_id = ?
       ORDER BY m.joined_at DESC`,
      [String(req.user.id)]
    );
    res.json({ status: 'success', classes });
  } catch (error) {
    console.error("GET JOINED CLASSES ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 5. Detail 1 kelas (dipakai dosen untuk menampilkan ulang token, dan
//    mahasiswa untuk header nama kelas yang sedang dibuka).
router.get('/classes/:classId', verifyToken, async (req, res) => {
  try {
    const [classes] = await pool.query(
      `SELECT c.*,
              (SELECT COUNT(*) FROM quizizz_class_members m WHERE m.class_id = c.id) AS member_count,
              (SELECT COUNT(*) FROM quizizz_quizzes q WHERE q.class_id = c.id) AS quiz_count
       FROM quizizz_classes c WHERE c.id = ?`,
      [req.params.classId]
    );
    if (classes.length === 0) return res.status(404).json({ status: 'gagal', message: 'Kelas tidak ditemukan' });
    res.json({ status: 'success', class: classes[0] });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 6. DOSEN: Daftar mahasiswa anggota kelas (dipakai halaman detail kelas).
router.get('/classes/:classId/members', verifyToken, async (req, res) => {
  try {
    const [members] = await pool.query(
      'SELECT student_id, student_name, joined_at FROM quizizz_class_members WHERE class_id = ? ORDER BY joined_at ASC',
      [req.params.classId]
    );
    res.json({ status: 'success', members });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 7. DOSEN: Hapus kelas secara PERMANEN. Ikut menghapus (cascade) seluruh
// kuis/PR, presentasi (beserta bank soal & sesi live-nya), dan flashcard
// yang terikat ke kelas ini, plus semua keanggotaan mahasiswa di kelas
// tersebut -- supaya tidak menyisakan data "yatim" di database.
router.delete('/classes/:classId', verifyToken, async (req, res) => {
  try {
    const classId = req.params.classId;
    const [rows] = await pool.query('SELECT dosen_id FROM quizizz_classes WHERE id = ?', [classId]);
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Kelas tidak ditemukan' });
    if (String(rows[0].dosen_id) !== String(req.user.id)) {
      return res.status(403).json({ status: 'gagal', message: 'Anda tidak berhak menghapus kelas ini' });
    }

    // Hapus kuis/PR beserta soal & submission-nya
    const [quizzes] = await pool.query('SELECT id FROM quizizz_quizzes WHERE class_id = ?', [classId]);
    for (const q of quizzes) {
      try { await pool.query('DELETE FROM quizizz_questions WHERE quiz_id = ?', [q.id]); } catch (_) {}
      try { await pool.query('DELETE FROM quizizz_sessions WHERE quiz_id = ?', [q.id]); } catch (_) {}
      try { await pool.query('DELETE FROM homework_assignments WHERE quiz_id = ?', [q.id]); } catch (_) {}
      try { await pool.query('DELETE FROM quizizz_homework_submissions WHERE session_id = ?', [q.id]); } catch (_) {}
      try { await pool.query('DELETE FROM homework_submissions WHERE homework_id = ?', [q.id]); } catch (_) {}
      try { await pool.query('DELETE FROM quizizz_game_sessions WHERE quiz_id = ?', [q.id]); } catch (_) {}
    }
    await pool.query('DELETE FROM quizizz_quizzes WHERE class_id = ?', [classId]);

    // Hapus presentasi beserta bank soal & sesi live-nya
    const [lessons] = await pool.query('SELECT id FROM quizizz_lessons WHERE class_id = ?', [classId]);
    for (const l of lessons) {
      try { await pool.query('DELETE FROM quizizz_lesson_questions WHERE lesson_id = ?', [l.id]); } catch (_) {}
      try { await pool.query('DELETE FROM quizizz_lesson_sessions WHERE lesson_id = ?', [l.id]); } catch (_) {}
    }
    await pool.query('DELETE FROM quizizz_lessons WHERE class_id = ?', [classId]);

    // Hapus flashcard yang terikat kelas ini
    try { await pool.query('DELETE FROM quizizz_flashcards WHERE class_id = ?', [classId]); } catch (_) {}

    // Hapus keanggotaan mahasiswa & kelasnya sendiri
    await pool.query('DELETE FROM quizizz_class_members WHERE class_id = ?', [classId]);
    await pool.query('DELETE FROM quizizz_classes WHERE id = ?', [classId]);

    res.json({ status: 'sukses', message: 'Kelas beserta seluruh isinya berhasil dihapus' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 8. MAHASISWA: Keluar dari kelas (hanya menghapus keanggotaan sendiri,
// TIDAK menghapus kelasnya -- mahasiswa lain & dosen tidak terpengaruh).
router.delete('/classes/:classId/leave', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'mahasiswa') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya mahasiswa yang dapat keluar dari kelas' });
    }
    await pool.query('DELETE FROM quizizz_class_members WHERE class_id = ? AND student_id = ?', [req.params.classId, String(req.user.id)]);
    res.json({ status: 'sukses', message: 'Berhasil keluar dari kelas' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 1. BUAT KUIS BARU ============
router.post('/quizzes', verifyToken, async (req, res) => {
  try {
    const { title, description, quiz_type, class_id } = req.body;
    if (!title) return res.status(400).json({ status: 'gagal', message: 'Judul kuis wajib diisi' });

    const id = uuidv4();
    const type = quiz_type || 'quiz';
    await pool.query(
      'INSERT INTO quizizz_quizzes (id, user_id, title, description, quiz_type, class_id) VALUES (?, ?, ?, ?, ?, ?)',
      [id, req.user.id, title, description || null, type, class_id || null]
    );

    res.status(201).json({ status: 'sukses', message: 'Kuis berhasil dibuat', quiz: { id, title, description, quiz_type: type, class_id: class_id || null } });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 2. AMBIL DAFTAR KUIS DOSEN ============
router.get('/quizzes/mine', verifyToken, async (req, res) => {
  try {
    const userId = req.user.id;
    // PENTING (fitur "Manajemen Kelas"): filter berdasarkan class_id kalau
    // dikirim dari frontend, supaya kuis Kelas A tidak tercampur/tampil di
    // Kelas B walau dibuat oleh dosen yang sama. Kalau class_id TIDAK
    // dikirim (mode lama / kuis umum di luar kelas), tampilkan kuis yang
    // class_id-nya NULL saja (bukan gabungan semua kelas), supaya tetap
    // terpisah rapi per kelas.
    const classId = req.query.class_id;
    const classFilter = classId ? 'AND q.class_id = ?' : 'AND q.class_id IS NULL';
    const params = classId ? [userId, classId] : [userId];

    const [quizzes] = await pool.query(
      `SELECT q.*, 
              (SELECT COUNT(*) FROM quizizz_questions qq WHERE qq.quiz_id = q.id) AS total_questions,
              (SELECT COUNT(*) FROM quizizz_game_sessions gs WHERE (gs.quiz_id = q.id OR gs.id = q.id) AND gs.mode = 'live') AS live_session_count,
              (SELECT COUNT(DISTINCT qa.question_id) 
               FROM quizizz_question_answers qa
               JOIN quizizz_game_sessions gs ON gs.id = qa.session_id
               WHERE gs.quiz_id = q.id AND qa.player_id IN 
                     (SELECT sp.id FROM quizizz_session_players sp WHERE sp.user_id = ?)) AS answered_count
       FROM quizizz_quizzes q
       WHERE q.user_id = ? ${classFilter}
       ORDER BY q.created_at DESC`,
      [userId, ...params]
    );

    const formatted = quizzes.map(q => {
      const hasLive = Boolean(q.live_session_count && q.live_session_count > 0);
      return {
        ...q,
        has_live_session: hasLive,
        has_live: hasLive,
        is_completed: q.total_questions > 0 && q.answered_count >= q.total_questions
      };
    });

    res.json({ status: 'success', quizzes: formatted });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 3. HAPUS KUIS PERMANEN (CASCADE DELETE) ============
router.delete('/quizzes/:id', verifyToken, async (req, res) => {
  try {
    const quizId = req.params.id;

    // 1. Delete all student answers, session players, and submissions linked to sessions of this quiz
    await pool.query(
      `DELETE FROM quizizz_question_answers WHERE session_id IN (
         SELECT id FROM quizizz_sessions WHERE quiz_id = ? UNION SELECT id FROM quizizz_game_sessions WHERE quiz_id = ?
       )`,
      [quizId, quizId]
    );
    await pool.query(
      `DELETE FROM quizizz_session_players WHERE session_id IN (
         SELECT id FROM quizizz_sessions WHERE quiz_id = ? UNION SELECT id FROM quizizz_game_sessions WHERE quiz_id = ?
       )`,
      [quizId, quizId]
    );
    await pool.query('DELETE FROM quizizz_homework_submissions WHERE session_id = ? OR session_id IN (SELECT id FROM quizizz_sessions WHERE quiz_id = ?)', [quizId, quizId]);
    await pool.query('DELETE FROM homework_submissions WHERE homework_id = ? OR homework_id IN (SELECT id FROM homework_assignments WHERE quiz_id = ?)', [quizId, quizId]);

    // 2. Cascade Delete all sessions linked to this quiz
    await pool.query('DELETE FROM quizizz_sessions WHERE quiz_id = ? OR id = ?', [quizId, quizId]);
    await pool.query('DELETE FROM homework_assignments WHERE quiz_id = ? OR id = ?', [quizId, quizId]);
    await pool.query('DELETE FROM quizizz_game_sessions WHERE quiz_id = ? OR id = ?', [quizId, quizId]);
    try { await pool.query('DELETE FROM quizizz_homework WHERE quiz_id = ? OR id = ?', [quizId, quizId]); } catch (_) {}

    // 3. Cascade Delete questions and quiz
    await pool.query('DELETE FROM quizizz_questions WHERE quiz_id = ?', [quizId]);
    await pool.query('DELETE FROM quizizz_quizzes WHERE id = ?', [quizId]);

    res.json({
      status: 'success',
      message: 'Sesi PR / Kuis berhasil dihapus secara permanen dari database.'
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 3b. RE-AKTIVASI KUIS KE BANK KUIS ============
const handleReactivateQuizToBank = async (req, res) => {
  try {
    const quizId = req.params.quizId || req.params.id;

    // 1. Verify quiz exists
    const [quizzes] = await pool.query('SELECT * FROM quizizz_quizzes WHERE id = ?', [quizId]);
    if (quizzes.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Kuis tidak ditemukan' });
    }

    // 2. Update status & clear history_status flag in quizizz_quizzes
    try {
      await pool.query("ALTER TABLE quizizz_quizzes ADD COLUMN history_status VARCHAR(50) DEFAULT NULL");
    } catch (_) {}
    try {
      await pool.query("UPDATE quizizz_quizzes SET status = 'active', history_status = NULL WHERE id = ?", [quizId]);
    } catch (_) {}

    // 3. Clear completed session statuses for this quiz
    try {
      await pool.query("UPDATE quizizz_game_sessions SET status = 'waiting' WHERE (quiz_id = ? OR id = ?) AND status = 'completed'", [quizId, quizId]);
      await pool.query("UPDATE quizizz_sessions SET status = 'active' WHERE (quiz_id = ? OR id = ?) AND status = 'completed'", [quizId, quizId]);
    } catch (_) {}

    res.json({
      status: 'success',
      message: 'Quiz successfully restored to question bank',
      quiz_id: String(quizId)
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.post('/quizzes/:quizId/reactivate-to-bank', verifyToken, handleReactivateQuizToBank);
router.post('/quizzes/:quizId/reactivate', verifyToken, handleReactivateQuizToBank);

// ============ 3c. AMBIL RIWAYAT KUIS DOSEN ============
router.get('/quizzes/history', verifyToken, async (req, res) => {
  try {
    const userId = req.user.id;
    const [quizzes] = await pool.query(
      `SELECT q.*, 
              (SELECT COUNT(*) FROM quizizz_questions qq WHERE qq.quiz_id = q.id) AS total_questions,
              (SELECT COUNT(*) FROM quizizz_game_sessions gs WHERE (gs.quiz_id = q.id OR gs.id = q.id)) AS live_session_count
       FROM quizizz_quizzes q
       WHERE q.user_id = ? AND (
         q.history_status = 'completed' OR 
         q.id IN (SELECT quiz_id FROM quizizz_game_sessions WHERE status IN ('completed', 'active', 'in_progress')) OR
         q.id IN (SELECT id FROM quizizz_game_sessions WHERE status IN ('completed', 'active', 'in_progress'))
       )
       ORDER BY q.created_at DESC`,
      [userId]
    );

    const formatted = quizzes.map(q => ({
      ...q,
      history_status: 'completed',
      has_live_session: true,
      status: 'completed'
    }));

    res.json({ status: 'success', quizzes: formatted, history: formatted });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 4. TAMBAH SOAL (MULTIPLE CHOICE, TRUE FALSE, MULTI SELECT, GAMBAR, TIMER) ============
const handleAddQuestion = async (req, res) => {
  try {
    const targetId = req.params.quizId || req.params.id;

    const {
      question,
      question_text,
      type,
      question_type,
      option_a,
      option_b,
      option_c,
      option_d,
      options,
      options_json,
      correct,
      correct_answer,
      correct_list,
      correct_list_json,
      correct_answers,
      image_url,
      timer_seconds,
      order_index,
      option_images,
    } = req.body;

    const finalQuestionText = question || question_text;
    if (!finalQuestionText) {
      return res.status(400).json({ status: 'gagal', message: 'Pertanyaan wajib diisi' });
    }

    const id = uuidv4();
    const qType = type || question_type || 'multiple_choice';
    const timerSec = parseInt(timer_seconds || 30);

    let parsedOptions = [];
    if (Array.isArray(options)) {
      parsedOptions = options;
    } else if (Array.isArray(options_json)) {
      parsedOptions = options_json;
    } else if (typeof options_json === 'string') {
      try { parsedOptions = JSON.parse(options_json); } catch (_) {}
    } else if (typeof options === 'string') {
      try { parsedOptions = JSON.parse(options); } catch (_) {}
    }

    const finalOptionA = option_a || (parsedOptions[0] ? String(parsedOptions[0]) : '');
    const finalOptionB = option_b || (parsedOptions[1] ? String(parsedOptions[1]) : '');
    const finalOptionC = option_c || (parsedOptions[2] ? String(parsedOptions[2]) : '');
    const finalOptionD = option_d || (parsedOptions[3] ? String(parsedOptions[3]) : '');

    const finalOptionsJson = parsedOptions.length
      ? JSON.stringify(parsedOptions)
      : (options_json ? (typeof options_json === 'string' ? options_json : JSON.stringify(options_json)) : null);

    let finalCorrectListJson = null;
    const rawList = correct_list_json || correct_list || correct_answers || (Array.isArray(correct) ? correct : (Array.isArray(correct_answer) ? correct_answer : null));
    if (rawList) {
      finalCorrectListJson = typeof rawList === 'string' ? rawList : JSON.stringify(rawList);
    }

    // FITUR "Perbaikan Bug PG Disalahkan" (poin 6): dulu kalau `correct`
    // yang dikirim ternyata string kosong / falsy, fallback-nya adalah
    // HURUF LITERAL 'A' -- padahal correct_answer seharusnya berisi TEKS
    // LENGKAP opsi jawaban (sama seperti yang dibandingkan mahasiswa saat
    // menjawab). Kalau options-nya berupa teks ("Jakarta", dst), correct_
    // answer = "A" TIDAK AKAN PERNAH cocok dengan teks apa pun, sehingga
    // soal itu selalu dianggap salah walau mahasiswa sudah menjawab benar.
    // Sekarang fallback-nya memakai TEKS OPSI PERTAMA yang tersedia, bukan
    // huruf 'A', supaya format correct_answer selalu konsisten dengan
    // format opsi jawabannya.
    const fallbackCorrect = parsedOptions.length > 0 ? String(parsedOptions[0]) : (finalOptionA || 'A');
    let finalCorrectAns = fallbackCorrect;
    const rawCorrect = correct !== undefined ? correct : correct_answer;
    if (typeof rawCorrect === 'string' && rawCorrect) {
      finalCorrectAns = rawCorrect;
    } else if (Array.isArray(rawCorrect) && rawCorrect.length > 0) {
      finalCorrectAns = String(rawCorrect[0]);
    } else if (finalCorrectListJson) {
      try {
        const arr = JSON.parse(finalCorrectListJson);
        if (Array.isArray(arr) && arr.length > 0) finalCorrectAns = String(arr[0]);
      } catch (_) {}
    }

    // FITUR "Gambar di Jawaban PG" (poin 5): gambar per-opsi jawaban,
    // dipangkas/di-null-kan supaya panjangnya selalu sama dengan jumlah
    // opsi yang tersimpan.
    const optsForImages = parsedOptions.length ? parsedOptions : [finalOptionA, finalOptionB, finalOptionC, finalOptionD].filter(Boolean);
    const rawOptionImages = Array.isArray(option_images) ? option_images : [];
    const finalOptionImages = optsForImages.map((_, i) => (rawOptionImages[i] && rawOptionImages[i].toString().trim().length > 0) ? rawOptionImages[i] : null);
    const hasAnyOptionImage = finalOptionImages.some(v => v !== null);
    const finalOptionImagesJson = hasAnyOptionImage ? JSON.stringify(finalOptionImages) : null;

    await pool.query(
      `INSERT INTO quizizz_questions
       (id, quiz_id, question_text, question_type, option_a, option_b, option_c, option_d, options_json, correct_answer, correct_list_json, image_url, option_images_json, timer_seconds, order_index, variable_calc_json)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        id,
        targetId,
        finalQuestionText,
        qType,
        finalOptionA,
        finalOptionB,
        finalOptionC,
        finalOptionD,
        finalOptionsJson,
        finalCorrectAns,
        finalCorrectListJson,
        image_url || null,
        finalOptionImagesJson,
        timerSec,
        order_index || 0,
        req.body.variable_calc_json || null,
      ]
    );

    res.status(201).json({
      status: 'success',
      message: 'Soal berhasil disimpan.',
      question_id: id,
      question: {
        id,
        quiz_id: targetId,
        question: finalQuestionText,
        question_text: finalQuestionText,
        type: qType,
        question_type: qType,
        options: parsedOptions.length ? parsedOptions : [finalOptionA, finalOptionB, finalOptionC, finalOptionD].filter(Boolean),
        correct: finalCorrectAns,
        correct_answer: finalCorrectAns,
        timer_seconds: timerSec,
        image_url: image_url || null,
        option_images: hasAnyOptionImage ? finalOptionImages : optsForImages.map(() => null)
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.post('/quizzes/:quizId/questions', handleAddQuestion);
router.post('/sessions/:id/questions', handleAddQuestion);

// ============ 5. LIHAT SOAL DALAM KUIS / SESI ============
const handleGetQuestions = async (req, res) => {
  try {
    const targetId = req.params.quizId || req.params.id;

    let [rows] = await pool.query(
      `SELECT * FROM quizizz_questions 
       WHERE quiz_id = ?
       ORDER BY order_index ASC`,
      [targetId]
    );

    // Fallback lookup if session has no individual questions yet
    if (rows.length === 0) {
      const [sRows] = await pool.query(
        `SELECT quiz_id FROM quizizz_sessions WHERE id = ?
         UNION SELECT quiz_id FROM homework_assignments WHERE id = ?
         UNION SELECT quiz_id FROM quizizz_game_sessions WHERE id = ?`,
        [targetId, targetId, targetId]
      );
      if (sRows.length > 0 && sRows[0].quiz_id !== targetId) {
        const [fallbackRows] = await pool.query(
          'SELECT * FROM quizizz_questions WHERE quiz_id = ? ORDER BY order_index ASC',
          [sRows[0].quiz_id]
        );
        rows = fallbackRows;
      }
    }

    const formattedQuestions = rows.map(q => {
      let opts = [];
      if (q.options_json) {
        try {
          opts = typeof q.options_json === 'string' ? JSON.parse(q.options_json) : q.options_json;
        } catch (_) {}
      }
      if (!Array.isArray(opts) || opts.length === 0) {
        opts = [q.option_a, q.option_b, q.option_c, q.option_d].filter(o => o !== null && o !== undefined && o !== '');
      }

      // FITUR "Perbaikan Bug PG Disalahkan" (poin 6): array correct_list_json
      // dulu bisa "bocor" jadi nilai `correct` walau soalnya BUKAN
      // multi_select (misal data lama / edge case), sehingga perbandingan
      // teks di sisi mahasiswa (String vs List) selalu gagal cocok dan
      // soal selalu dianggap salah. Sekarang override array HANYA berlaku
      // untuk question_type multi_select. Default fallback juga diganti
      // dari huruf literal 'A' ke teks opsi pertama (kalau ada), supaya
      // tidak terjadi mismatch huruf vs teks opsi.
      let correctVal = q.correct_answer || (opts.length > 0 ? opts[0] : 'A');
      if (q.question_type === 'multi_select' && q.correct_list_json) {
        try {
          const parsed = typeof q.correct_list_json === 'string' ? JSON.parse(q.correct_list_json) : q.correct_list_json;
          if (Array.isArray(parsed) && parsed.length > 0) correctVal = parsed;
        } catch (_) {}
      }

      // FITUR "Gambar di Jawaban PG" (poin 5): parse gambar per-opsi
      // (kalau ada) supaya frontend bisa menampilkannya di samping teks
      // opsi jawaban.
      let optionImages = opts.map(() => null);
      if (q.option_images_json) {
        try {
          const parsedImgs = typeof q.option_images_json === 'string' ? JSON.parse(q.option_images_json) : q.option_images_json;
          if (Array.isArray(parsedImgs)) {
            optionImages = opts.map((_, i) => i < parsedImgs.length ? (parsedImgs[i] || null) : null);
          }
        } catch (_) {}
      }

      return {
        id: String(q.id),
        quiz_id: String(q.quiz_id),
        question: q.question_text,
        question_text: q.question_text,
        type: q.question_type || 'multiple_choice',
        question_type: q.question_type || 'multiple_choice',
        options: opts,
        options_json: opts,
        option_images: optionImages,
        correct: correctVal,
        correct_answer: correctVal,
        timer_seconds: q.timer_seconds || 30,
        image_url: q.image_url || null,
        order_index: q.order_index || 0,
        variable_calc_json: q.variable_calc_json || null
      };
    });

    res.json({ status: 'success', questions: formattedQuestions });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/quizzes/:quizId/questions', handleGetQuestions);
router.get('/sessions/:id/questions', handleGetQuestions);

// ============ 5b. HAPUS SOAL DARI DATABASE (DELETE /api/quizizz/questions/:questionId) ============
const handleDeleteQuestion = async (req, res) => {
  try {
    const questionId = req.params.questionId || req.params.id;
    await pool.query('DELETE FROM quizizz_question_answers WHERE question_id = ?', [questionId]);
    await pool.query('DELETE FROM quizizz_questions WHERE id = ?', [questionId]);
    res.json({
      status: 'success',
      message: 'Soal berhasil dihapus dari database.'
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.delete('/questions/:questionId', handleDeleteQuestion);

// ============ 5c. UPLOAD GAMBAR SOAL (POST /api/quizizz/upload-image) ============
const handleQuestionImageUpload = (req, res) => {
  try {
    const file = req.file;
    if (!file) {
      return res.status(400).json({ status: 'gagal', message: 'File gambar wajib diunggah (field: image atau file)' });
    }

    const host = req.headers.host || 'localhost:3000';
    const protocol = req.protocol || 'http';
    const publicUrl = `${protocol}://${host}/uploads/questions/${file.filename}`;

    res.json({
      status: 'success',
      message: 'Gambar soal berhasil diunggah',
      image_url: publicUrl,
      url: publicUrl,
      filename: file.filename
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.post('/upload-image', (req, res, next) => {
  uploadQuestionImg.single('image')(req, res, (err) => {
    if (err || !req.file) {
      return uploadQuestionImg.single('file')(req, res, (err2) => {
        if (err2 || !req.file) {
          return uploadQuestionImg.single('photo')(req, res, (err3) => {
            handleQuestionImageUpload(req, res);
          });
        }
        handleQuestionImageUpload(req, res);
      });
    }
    handleQuestionImageUpload(req, res);
  });
});

// ============ 6. BUAT GAME SESSION / KUIS BARU ============
router.post('/sessions', async (req, res) => {
  try {
    let { quiz_id, title, description, quiz_type, mode, deadline, shuffle_questions, shuffle_answers } = req.body;
    
    if (!quiz_id && !title) {
      return res.status(400).json({ status: 'gagal', message: 'quiz_id atau title wajib diisi' });
    }

    let hostId = null;
    const authHeader = req.headers['authorization'];
    if (authHeader && authHeader.startsWith('Bearer ')) {
      try {
        const jwt = require('jsonwebtoken');
        const decoded = jwt.verify(authHeader.split(' ')[1], process.env.JWT_SECRET);
        hostId = decoded.id;
      } catch (e) {}
    }

    if (!quiz_id && title) {
      quiz_id = uuidv4();
      await pool.query(
        'INSERT INTO quizizz_quizzes (id, user_id, title, description, quiz_type) VALUES (?, ?, ?, ?, ?)',
        [quiz_id, hostId || '1', title, description || null, quiz_type || 'quiz']
      );
    }

    // PENTING: judul/deskripsi sesi HARUS mengikuti kuis ASLI (quizizz_quizzes)
    // yang sudah dibuat dosen, bukan fallback generik "Live Host Gamifikasi".
    // Fallback generik yang lama menyebabkan quiz "hantu" (ghost) bertajuk
    // "Live Host Gamifikasi" ikut ter-insert ke Bank Kuis setiap kali dosen
    // menekan "Mulai Live Host Gamifikasi" ATAU menugaskan PR.
    if (!title) {
      try {
        const [qRows] = await pool.query('SELECT title, description FROM quizizz_quizzes WHERE id = ?', [String(quiz_id)]);
        if (qRows.length) {
          title = qRows[0].title;
          if (!description) description = qRows[0].description;
        }
      } catch (_) {}
    }
    title = title || 'Kuis Gamifikasi';

    const id = uuidv4();
    const pin = generatePin();
    const sessionMode = mode || 'live';
    const initialStatus = sessionMode === 'live' ? 'waiting' : 'active';

    let formattedDeadline = deadline;
    if (typeof deadline === 'string' && deadline.includes('T')) {
      formattedDeadline = deadline.replace('T', ' ').replace('Z', '').split('.')[0];
    }

    // Insert into quizizz_sessions
    await pool.query(
      'INSERT INTO quizizz_sessions (id, quiz_id, host_id, mode, title, description, deadline, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, String(quiz_id), hostId, sessionMode, title, description || '', formattedDeadline || null, initialStatus]
    );

    // CATATAN: TIDAK insert baris baru ke quizizz_quizzes di sini lagi.
    // Sesi (baik live host maupun PR) selalu MENGACU ke quiz_id yang sudah
    // ada — tidak boleh membuat baris kuis "hantu" baru memakai id sesi.
    // (Baris insert quizizz_quizzes tambahan yang lama sudah DIHAPUS —
    // itulah sumber duplikasi "Live Host Gamifikasi" di Bank Kuis.)

    // Sync with quizizz_game_sessions
    try {
      await pool.query(
        'INSERT INTO quizizz_game_sessions (id, quiz_id, host_id, pin, mode, deadline, status, shuffle_questions, shuffle_answers) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [id, String(quiz_id), hostId || '1', pin, sessionMode, formattedDeadline || null, initialStatus, shuffle_questions ? 1 : 0, shuffle_answers ? 1 : 0]
      );
    } catch (_) {}

    // Sync with homework_assignments (hanya untuk mode homework)
    if (sessionMode === 'homework') {
      try {
        await pool.query(
          'INSERT INTO homework_assignments (id, quiz_id, dosen_id, title, description, deadline) VALUES (?, ?, ?, ?, ?, ?)',
          [id, String(quiz_id), hostId, title, description || '', formattedDeadline || '2026-12-31 23:59:59']
        );
      } catch (_) {}
    }

    // CATATAN: TIDAK lagi menduplikasi/mengkloning soal ke ID baru. Sesi
    // (live maupun PR) mengambil soal LANGSUNG dari quiz_id aslinya lewat
    // fallback yang sudah ada di endpoint GET soal/sesi — supaya "Kelola
    // Soal" pada Bank Kuis dan pada sesi/PR turunannya selalu 100% sinkron
    // dengan SATU sumber data yang sama, tanpa duplikat yang bisa basi.

    res.status(201).json({
      status: 'success',
      message: 'Sesi game / PR berhasil dibuat',
      session: {
        id,
        quiz_id,
        pin,
        session_code: pin,
        status: initialStatus,
        mode: sessionMode,
        title,
        description: description || '',
        deadline: formattedDeadline
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 7. PEKERJAAN RUMAH (HOMEWORK) REST API ENDPOINTS ============

// 7a. GET /api/quizizz/sessions/homework?userId=all (Mahasiswa Mengambil Daftar PR Aktif Lintas Perangkat)
const handleGetHomeworkSessionsWithQuestions = async (req, res) => {
  try {
    // PENTING (fitur "Aktifkan PR"): PR yang baru dibuat berstatus 'draft'
    // dan TIDAK boleh terlihat mahasiswa sampai dosen menekan tombol
    // "Aktifkan". Endpoint ini dipakai bersama oleh halaman Dosen (yang
    // perlu melihat draft supaya bisa menekan Aktifkan) dan halaman
    // Mahasiswa (yang HANYA boleh melihat PR berstatus 'active'). Dosen
    // memanggil endpoint ini dengan query ?include_draft=1.
    const includeDraft = req.query.include_draft === '1' || req.query.include_draft === 'true';
    // PENTING (fitur "Manajemen Kelas"): filter PR berdasarkan kelas lewat
    // JOIN ke quizizz_quizzes.class_id (kuis PR ini dibuat dari), supaya PR
    // Kelas A tidak tercampur ke Kelas B. class_id dikirim via query param.
    const classId = req.query.class_id;

    const [rows] = await pool.query(
      `SELECT s.id, s.quiz_id, s.host_id, s.mode, s.title, s.description, s.deadline, s.status, s.created_at,
              q.title AS quiz_title, q.description AS quiz_description, q.class_id AS class_id
       FROM (
         SELECT id, quiz_id, host_id, mode, title, description, deadline, status, created_at FROM quizizz_sessions WHERE (status IS NULL OR status != 'deleted') AND (mode = 'homework' OR status = 'active')
         UNION
         SELECT id, quiz_id, dosen_id AS host_id, 'homework' AS mode, title, description, deadline, COALESCE(status, 'active') AS status, created_at FROM homework_assignments
         UNION
         SELECT id, quiz_id, host_id, mode, (SELECT title FROM quizizz_quizzes WHERE id = quizizz_game_sessions.quiz_id) AS title, (SELECT description FROM quizizz_quizzes WHERE id = quizizz_game_sessions.quiz_id) AS description, deadline, status, created_at FROM quizizz_game_sessions WHERE mode = 'homework' AND (status IS NULL OR status != 'deleted')
       ) s
       LEFT JOIN quizizz_quizzes q ON q.id = s.quiz_id
       WHERE (s.status IS NULL OR s.status != 'deleted')
         ${includeDraft ? '' : "AND (s.status IS NULL OR s.status != 'draft')"}
         ${classId ? 'AND q.class_id = ?' : 'AND q.class_id IS NULL'}
       ORDER BY s.created_at DESC`,
      classId ? [classId] : []
    );

    const uniqueMap = new Map();
    for (const r of rows) {
      const key = r.id || r.quiz_id;
      if (!uniqueMap.has(key)) {
        uniqueMap.set(key, r);
      }
    }
    const uniqueRows = Array.from(uniqueMap.values());

    const sessionsWithQuestions = await Promise.all(uniqueRows.map(async (sess) => {
      const [qRows] = await pool.query(
        'SELECT * FROM quizizz_questions WHERE quiz_id = ? ORDER BY order_index ASC',
        [sess.quiz_id]
      );

      const formattedQuestions = qRows.map(q => {
        let opts = [];
        if (q.options_json) {
          try {
            opts = typeof q.options_json === 'string' ? JSON.parse(q.options_json) : q.options_json;
          } catch (_) {}
        }
        if (!Array.isArray(opts) || opts.length === 0) {
          opts = [q.option_a, q.option_b, q.option_c, q.option_d].filter(o => o !== null && o !== undefined && o !== '');
        }

        // FITUR "Perbaikan Bug PG Disalahkan" (poin 6): lihat penjelasan
        // di handleGetQuestions -- override array HANYA untuk multi_select,
        // default fallback pakai teks opsi pertama bukan huruf 'A'.
        let correctVal = q.correct_answer || (opts.length > 0 ? opts[0] : 'A');
        if (q.question_type === 'multi_select' && q.correct_list_json) {
          try {
            const parsed = typeof q.correct_list_json === 'string' ? JSON.parse(q.correct_list_json) : q.correct_list_json;
            if (Array.isArray(parsed) && parsed.length > 0) correctVal = parsed;
          } catch (_) {}
        }

        // FITUR "Gambar di Jawaban PG" (poin 5).
        let optionImages = opts.map(() => null);
        if (q.option_images_json) {
          try {
            const parsedImgs = typeof q.option_images_json === 'string' ? JSON.parse(q.option_images_json) : q.option_images_json;
            if (Array.isArray(parsedImgs)) {
              optionImages = opts.map((_, i) => i < parsedImgs.length ? (parsedImgs[i] || null) : null);
            }
          } catch (_) {}
        }

        return {
          id: String(q.id),
          question: q.question_text,
          question_text: q.question_text,
          type: q.question_type || 'multiple_choice',
          question_type: q.question_type || 'multiple_choice',
          options: opts,
          options_json: opts,
          option_images: optionImages,
          correct: correctVal,
          correct_answer: correctVal,
          timer_seconds: q.timer_seconds || 30,
          image_url: q.image_url || null,
          variable_calc_json: q.variable_calc_json || null
        };
      });

      let formattedCreatedAt = sess.created_at;
      if (sess.created_at) {
        try { formattedCreatedAt = new Date(sess.created_at).toISOString(); } catch (_) {}
      } else {
        formattedCreatedAt = new Date().toISOString();
      }

      let formattedDeadline = sess.deadline;
      if (sess.deadline) {
        try { formattedDeadline = new Date(sess.deadline).toISOString(); } catch (_) {}
      }

      return {
        id: String(sess.id),
        session_id: String(sess.id),
        quiz_id: String(sess.quiz_id),
        mode: sess.mode || 'homework',
        title: sess.title || sess.quiz_title || 'PR Mandiri Pemrograman Web',
        description: sess.description || sess.quiz_description || '',
        deadline: formattedDeadline,
        created_at: formattedCreatedAt,
        status: sess.status || 'active',
        total_questions: formattedQuestions.length,
        questions: formattedQuestions
      };
    }));

    res.json({
      status: 'success',
      sessions: sessionsWithQuestions,
      homeworks: sessionsWithQuestions,
      homework: sessionsWithQuestions
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/sessions/homework', handleGetHomeworkSessionsWithQuestions);
router.get('/homework', handleGetHomeworkSessionsWithQuestions);
router.get('/homework/assigned', handleGetHomeworkSessionsWithQuestions);

// 7b. POST /api/quizizz/homework & /assign
const handleCreateHomework = async (req, res) => {
  try {
    const { quiz_id, title, description, deadline } = req.body;
    if (!quiz_id || !title || !deadline) {
      return res.status(400).json({ status: 'gagal', message: 'quiz_id, title, dan deadline wajib diisi' });
    }

    const id = uuidv4();
    let dosenId = null;
    if (req.user && req.user.id) dosenId = String(req.user.id);

    let formattedDeadline = deadline;
    if (typeof deadline === 'string' && deadline.includes('T')) {
      formattedDeadline = deadline.replace('T', ' ').replace('Z', '').split('.')[0];
    }

    // PENTING (fitur "Aktifkan PR"): PR baru dibuat berstatus 'draft' secara
    // default, supaya BELUM langsung tampil di halaman mahasiswa. Baru
    // setelah dosen menekan tombol "Aktifkan" (PATCH .../homework/:id/status
    // {status:'active'}), PR akan muncul di daftar aktif mahasiswa. Kirim
    // { "activate": true } pada body untuk membuat PR yang langsung aktif
    // (dipertahankan untuk kompatibilitas alur lama bila dibutuhkan).
    const initialStatus = req.body.activate === true ? 'active' : 'draft';

    await pool.query(
      'INSERT INTO quizizz_sessions (id, quiz_id, host_id, mode, title, description, deadline, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, String(quiz_id), dosenId, 'homework', title, description || '', formattedDeadline, initialStatus]
    );

    try {
      await pool.query(
        'INSERT INTO homework_assignments (id, quiz_id, dosen_id, title, description, deadline, status) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [id, String(quiz_id), dosenId, title, description || '', formattedDeadline, initialStatus]
      );
    } catch (_) {}

    res.status(201).json({
      status: 'sukses',
      message: initialStatus === 'active' ? 'Pekerjaan Rumah berhasil ditugaskan' : 'Pekerjaan Rumah berhasil dibuat sebagai draft. Tekan "Aktifkan" agar tampil ke mahasiswa.',
      homework: { id, quiz_id, title, description, deadline: formattedDeadline, status: initialStatus }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.post('/homework', handleCreateHomework);
router.post('/homework/assign', handleCreateHomework);

// 7c. PATCH /api/quizizz/sessions/:sessionId/deadline (Dosen Mengubah Deadline PR)
const handleUpdateSessionDeadline = async (req, res) => {
  try {
    const sessionId = req.params.sessionId || req.params.id;
    const { deadline } = req.body;
    if (!deadline) return res.status(400).json({ status: 'gagal', message: 'deadline wajib diisi' });

    let formattedDeadline = deadline;
    if (typeof deadline === 'string' && deadline.includes('T')) {
      formattedDeadline = deadline.replace('T', ' ').replace('Z', '').split('.')[0];
    }

    await pool.query('UPDATE quizizz_sessions SET deadline = ?, updated_at = NOW() WHERE id = ? OR quiz_id = ?', [formattedDeadline, sessionId, sessionId]);
    try { await pool.query('UPDATE homework_assignments SET deadline = ?, updated_at = NOW() WHERE id = ? OR quiz_id = ?', [formattedDeadline, sessionId, sessionId]); } catch (_) {}
    try { await pool.query('UPDATE quizizz_game_sessions SET deadline = ? WHERE id = ? OR quiz_id = ?', [formattedDeadline, sessionId, sessionId]); } catch (_) {}

    res.json({ status: 'sukses', message: 'Deadline PR berhasil diperbarui', deadline: formattedDeadline });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.patch('/sessions/:sessionId/deadline', handleUpdateSessionDeadline);
router.put('/sessions/:sessionId/deadline', handleUpdateSessionDeadline);
router.patch('/homework/:id/deadline', handleUpdateSessionDeadline);
router.put('/homework/:id/deadline', handleUpdateSessionDeadline);

// 7d. DELETE /api/quizizz/sessions/:sessionId?delete_quiz=true|false
const handleDeleteSessionOrHomework = async (req, res) => {
  try {
    const sessionId = req.params.sessionId || req.params.id;
    const deleteQuiz = req.query.delete_quiz === 'true' || req.query.restore_to_bank === 'false';

    const [sRows] = await pool.query(
      `SELECT quiz_id FROM quizizz_sessions WHERE id = ? OR quiz_id = ?
       UNION SELECT quiz_id FROM homework_assignments WHERE id = ? OR quiz_id = ?
       UNION SELECT quiz_id FROM quizizz_game_sessions WHERE id = ? OR quiz_id = ?`,
      [sessionId, sessionId, sessionId, sessionId, sessionId, sessionId]
    );
    const quizId = sRows.length ? sRows[0].quiz_id : sessionId;

    // Hard Delete student answers and players connected to the session
    await pool.query('DELETE FROM quizizz_question_answers WHERE session_id = ? OR session_id = ?', [sessionId, quizId]);
    await pool.query('DELETE FROM quizizz_session_players WHERE session_id = ? OR session_id = ?', [sessionId, quizId]);
    await pool.query('DELETE FROM quizizz_homework_submissions WHERE session_id = ? OR session_id IN (SELECT id FROM quizizz_sessions WHERE quiz_id = ?)', [sessionId, quizId]);
    await pool.query('DELETE FROM homework_submissions WHERE homework_id = ? OR homework_id IN (SELECT id FROM homework_assignments WHERE quiz_id = ?)', [sessionId, quizId]);

    // Hard Delete session assignments
    await pool.query('DELETE FROM quizizz_sessions WHERE id = ? OR quiz_id = ?', [sessionId, quizId]);
    await pool.query('DELETE FROM homework_assignments WHERE id = ? OR quiz_id = ?', [sessionId, quizId]);
    await pool.query('DELETE FROM quizizz_game_sessions WHERE id = ? OR quiz_id = ?', [sessionId, quizId]);
    try { await pool.query('DELETE FROM quizizz_homework WHERE id = ? OR quiz_id = ?', [sessionId, quizId]); } catch (_) {}

    if (deleteQuiz && quizId) {
      await pool.query('DELETE FROM quizizz_questions WHERE quiz_id = ?', [quizId]);
      await pool.query('DELETE FROM quizizz_quizzes WHERE id = ?', [quizId]);
    }

    res.json({
      status: 'success',
      message: 'Sesi PR / Kuis berhasil dihapus secara permanen dari database.'
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.delete('/sessions/:sessionId', handleDeleteSessionOrHomework);
router.delete('/homework/:id', handleDeleteSessionOrHomework);

// 7d-2. PATCH /api/quizizz/homework/:id/status (Nonaktifkan / Aktifkan Kembali PR
// TANPA menghapus data) — dipakai fitur "Nonaktifkan" PR dosen. Berbeda dari
// handleDeleteSessionOrHomework di atas yang menghapus PERMANEN beserta semua
// jawaban mahasiswa; endpoint ini hanya menyembunyikan PR dari daftar aktif
// mahasiswa (lintas device) sambil tetap menyimpan seluruh hasil pengerjaan
// untuk direkap di Laporan Rekap.
const handleSetHomeworkStatus = async (req, res) => {
  try {
    const targetId = req.params.id;
    const { status } = req.body;
    const finalStatus = (status === 'active') ? 'active' : 'deleted';

    const [sRows] = await pool.query(
      `SELECT quiz_id FROM quizizz_sessions WHERE id = ? OR quiz_id = ?
       UNION SELECT quiz_id FROM homework_assignments WHERE id = ? OR quiz_id = ?
       UNION SELECT quiz_id FROM quizizz_game_sessions WHERE id = ? OR quiz_id = ?`,
      [targetId, targetId, targetId, targetId, targetId, targetId]
    );
    const quizId = sRows.length ? sRows[0].quiz_id : targetId;

    await pool.query('UPDATE homework_assignments SET status = ? WHERE id = ? OR quiz_id = ?', [finalStatus, targetId, quizId]);
    await pool.query('UPDATE quizizz_sessions SET status = ? WHERE id = ? OR quiz_id = ?', [finalStatus, targetId, quizId]);
    await pool.query('UPDATE quizizz_game_sessions SET status = ? WHERE id = ? OR quiz_id = ?', [finalStatus, targetId, quizId]);

    res.json({
      status: 'success',
      message: finalStatus === 'deleted' ? 'PR berhasil dinonaktifkan' : 'PR berhasil diaktifkan kembali',
      new_status: finalStatus
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.patch('/homework/:id/status', handleSetHomeworkStatus);

// 7d-3. GET /api/quizizz/homework/deactivated (Daftar PR yang telah dinonaktifkan
// dosen, dipakai halaman Laporan Rekap untuk menampilkan riwayat + hasil PR)
const handleGetDeactivatedHomework = async (req, res) => {
  try {
    const [rows] = await pool.query(
      `SELECT h.id, h.quiz_id, h.title, h.description, h.deadline, h.created_at,
              q.title AS quiz_title
       FROM homework_assignments h
       LEFT JOIN quizizz_quizzes q ON q.id = h.quiz_id
       WHERE h.status = 'deleted'
       ORDER BY h.created_at DESC`
    );
    res.json({ status: 'success', homeworks: rows });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/homework/deactivated', handleGetDeactivatedHomework);

// 7e. GET /api/quizizz/sessions/:sessionId/submissions (Dosen Mengambil Rekap Nilai Seluruh Mahasiswa)
const handleGetSessionSubmissions = async (req, res) => {
  try {
    const sessionId = req.params.sessionId || req.params.id;
    const [subs] = await pool.query(
      `SELECT * FROM (
         SELECT id, session_id, student_name, student_id, score, total_questions, submitted_at, answers_json FROM quizizz_homework_submissions WHERE session_id = ? OR session_id IN (SELECT id FROM quizizz_sessions WHERE quiz_id = ?)
         UNION
         SELECT id, homework_id AS session_id, student_name, student_id, score, total_questions, submitted_at, answers_json FROM homework_submissions WHERE homework_id = ? OR homework_id IN (SELECT id FROM homework_assignments WHERE quiz_id = ?)
       ) t ORDER BY submitted_at DESC`,
      [sessionId, sessionId, sessionId, sessionId]
    );

    const formattedSubmissions = (subs || []).map((s, index) => {
      let parsedAnswers = [];
      if (s.answers_json) {
        try { parsedAnswers = typeof s.answers_json === 'string' ? JSON.parse(s.answers_json) : s.answers_json; } catch (_) { parsedAnswers = []; }
      }
      return {
        id: String(s.id),
        session_id: String(s.session_id),
        homework_id: String(s.session_id),
        student_name: s.student_name || 'Mahasiswa',
        student_id: s.student_id ? String(s.student_id) : null,
        score: parseInt(s.score || 0),
        total_questions: parseInt(s.total_questions || 0),
        answers: parsedAnswers,
        submitted_at: s.submitted_at ? new Date(s.submitted_at).toISOString() : new Date().toISOString()
      };
    });

    const totalSubmissions = formattedSubmissions.length;
    const highestScore = totalSubmissions > 0 ? Math.max(...formattedSubmissions.map(s => s.score)) : 0;
    const avgScore = totalSubmissions > 0 ? Math.round(formattedSubmissions.reduce((acc, curr) => acc + curr.score, 0) / totalSubmissions) : 0;

    res.json({
      status: 'success',
      total_submissions: totalSubmissions,
      average_score: avgScore,
      highest_score: highestScore,
      submissions: formattedSubmissions,
      results: formattedSubmissions
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/sessions/:sessionId/submissions', handleGetSessionSubmissions);
router.get('/homework/:id/submissions', handleGetSessionSubmissions);

// 7f. Student Submit Homework Score (POST /api/quizizz/sessions/:sessionId/submit & /homework/:id/submit)
const handleStudentHomeworkSubmit = async (req, res) => {
  try {
    const homeworkId = req.params.sessionId || req.params.id;
    const { student_name, student_id, score, total_questions, player_id, question_id, answer, answers } = req.body;

    // If single question submit or batch answers array submit is passed:
    if ((question_id && answer !== undefined) || Array.isArray(answers)) {
      // Handled by single/batch answer evaluation logic
    }

    if (!student_name && !player_id) {
      return res.status(400).json({ status: 'gagal', message: 'student_name wajib diisi' });
    }

    const name = student_name || `Mhs-${student_id || player_id}`;
    const subId = uuidv4();

    const [hwRows] = await pool.query(
      `SELECT id, deadline FROM homework_assignments WHERE id = ? OR quiz_id = ?
       UNION SELECT id, deadline FROM quizizz_sessions WHERE id = ? OR quiz_id = ?`,
      [homeworkId, homeworkId, homeworkId, homeworkId]
    );

    let resolvedHwId = homeworkId;
    let isLate = false;

    if (hwRows.length > 0) {
      resolvedHwId = hwRows[0].id;
      if (hwRows[0].deadline) {
        const deadlineTime = new Date(hwRows[0].deadline).getTime();
        if (Date.now() > deadlineTime) isLate = true;
      }
    }

    const submissionStatus = isLate ? 'Terlambat' : 'Selesai (Tepat Waktu)';

    // PENTING (fitur "Riwayat Jawaban PR"): simpan detail jawaban PER SOAL
    // (bukan cuma skor total), supaya mahasiswa & dosen bisa melihat soal
    // mana saja yang dijawab benar/salah di halaman Riwayat.
    const answersJson = Array.isArray(answers) ? JSON.stringify(answers) : null;

    try {
      await pool.query(
        'INSERT INTO quizizz_homework_submissions (id, session_id, student_name, student_id, score, total_questions, answers_json) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [subId, resolvedHwId, name, student_id || null, parseInt(score || 0), parseInt(total_questions || 0), answersJson]
      );
    } catch (_) {}

    try {
      await pool.query(
        'INSERT INTO homework_submissions (id, homework_id, student_name, student_id, score, total_questions, status, answers_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        [subId, resolvedHwId, name, student_id || null, parseInt(score || 0), parseInt(total_questions || 0), submissionStatus, answersJson]
      );
    } catch (_) {}

    res.status(201).json({
      status: 'sukses',
      message: 'Hasil PR berhasil dikirim',
      submission: {
        id: subId,
        session_id: resolvedHwId,
        homework_id: resolvedHwId,
        student_name: name,
        score: parseInt(score || 0),
        total_questions: parseInt(total_questions || 0),
        status: submissionStatus,
        answers: Array.isArray(answers) ? answers : [],
        submitted_at: new Date().toISOString()
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.post('/sessions/:sessionId/submit', handleStudentHomeworkSubmit);
router.post('/homework/:id/submit', handleStudentHomeworkSubmit);

// ============ 8. HAPUS SESI GAME ============
router.delete('/sessions/:sessionId', verifyToken, async (req, res) => {
  try {
    const { sessionId } = req.params;
    await pool.query('DELETE FROM quizizz_question_answers WHERE session_id = ?', [sessionId]);
    await pool.query('DELETE FROM quizizz_session_players WHERE session_id = ?', [sessionId]);
    await pool.query('DELETE FROM quizizz_game_sessions WHERE id = ?', [sessionId]);
    res.json({ status: 'sukses', message: 'Tugas mandiri berhasil dihapus' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 2b. ALIAS GET /sessions/mine ============
router.get('/sessions/mine', verifyToken, async (req, res) => {
  try {
    const userId = req.user.id;
    const [quizzes] = await pool.query(
      `SELECT q.*, 
              (SELECT COUNT(*) FROM quizizz_questions qq WHERE qq.quiz_id = q.id) AS total_questions
       FROM quizizz_quizzes q
       WHERE q.user_id = ?
       ORDER BY q.created_at DESC`,
      [userId]
    );

    res.json({ status: 'sukses', sessions: quizzes, quizzes });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 9. WAITING ROOM STATUS POLLING & TRANSITION ============

// 9a. Polling Status Waiting Room (Mahasiswa Poll / Backup Fallback)
const handleGetSessionStatus = async (req, res) => {
  try {
    const pin = (req.params.pin || req.params.sessionId || req.params.id || '').trim();
    const [rows] = await pool.query(
      `SELECT id, quiz_id, pin, status, mode, started_at FROM quizizz_game_sessions WHERE pin = ? OR id = ? OR quiz_id = ?
       UNION
       SELECT id, quiz_id, id AS pin, status, mode, NULL AS started_at FROM quizizz_sessions WHERE id = ? OR quiz_id = ?`,
      [pin, pin, pin, pin, pin]
    );

    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    const s = rows[0];
    const isAnyActive = rows.some(r => r.status === 'active' || r.status === 'in_progress' || r.status === 'started');
    const currentStatus = isAnyActive ? 'active' : (s.status || 'waiting');
    const isActive = isAnyActive || currentStatus === 'active';
    const startedAtRow = rows.find(r => r.started_at) || {};

    res.json({
      status: 'success',
      session_status: currentStatus,
      status: currentStatus,
      is_active: isActive,
      is_started: isActive,
      started_at: startedAtRow.started_at ? new Date(startedAtRow.started_at).toISOString() : null,
      session: {
        ...s,
        status: currentStatus,
        session_status: currentStatus,
        is_active: isActive,
        is_started: isActive,
        started_at: startedAtRow.started_at ? new Date(startedAtRow.started_at).toISOString() : null
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/sessions/pin/:pin/status', handleGetSessionStatus);
router.get('/sessions/:sessionId/status', handleGetSessionStatus);
router.get('/sessions/:id/status', handleGetSessionStatus);

// 9b. Update Status Waiting Room (Dosen Host Tekan Mulai Room)
const handleUpdateSessionStatus = async (req, res) => {
  try {
    const target = (req.params.pin || req.params.sessionId || req.params.id || '').trim();
    const { status } = req.body;
    if (!status) return res.status(400).json({ status: 'gagal', message: 'status wajib diisi' });

    let finalStatus = status;
    if (status === 'in_progress' || status === 'started') finalStatus = 'active';

    await pool.query(
      'UPDATE quizizz_game_sessions SET status = ? WHERE pin = ? OR id = ? OR quiz_id = ?',
      [finalStatus, target, target, target]
    );
    // started_at diisi HANYA SEKALI, persis saat status pertama kali menjadi
    // 'active' (dan belum pernah diisi sebelumnya) — supaya waktu mulai
    // benar-benar konsisten untuk seluruh mahasiswa yang join, tidak berubah
    // lagi walau endpoint ini dipanggil ulang di kemudian hari.
    if (finalStatus === 'active') {
      try {
        await pool.query(
          `UPDATE quizizz_game_sessions SET started_at = NOW() WHERE (pin = ? OR id = ? OR quiz_id = ?) AND started_at IS NULL`,
          [target, target, target]
        );
      } catch (_) {}
    }
    await pool.query(
      'UPDATE quizizz_sessions SET status = ? WHERE id = ? OR quiz_id = ?',
      [finalStatus, target, target]
    );
    await pool.query(
      'UPDATE quizizz_live_sessions SET status = ? WHERE session_code = ? OR id = ? OR quiz_id = ?',
      [finalStatus, target, target, target]
    );

    // Resolve session ID and PIN
    let resolvedPin = target;
    let resolvedSessionId = target;
    try {
      const [sRows] = await pool.query('SELECT id, pin FROM quizizz_game_sessions WHERE pin = ? OR id = ?', [target, target]);
      if (sRows.length > 0) {
        resolvedPin = sRows[0].pin || target;
        resolvedSessionId = sRows[0].id || target;
      }
    } catch (_) {}

    // Socket.io Real-time Event Broadcast for instant transition (0.1s)
    try {
      const io = req.app.get('io');
      if (io) {
        const payload = {
          pin: resolvedPin,
          session_code: resolvedPin,
          sessionId: resolvedSessionId,
          session_id: resolvedSessionId,
          status: finalStatus,
          session_status: finalStatus,
          is_active: finalStatus === 'active',
          is_started: finalStatus === 'active'
        };

        // Broadcast to all event name variations
        io.emit('session_status_update', payload);
        io.emit('room_status_changed', payload);
        io.emit('session_status_changed', payload);

        // Broadcast to channel variations including session_:pin
        const channels = [
          target,
          `session_${target}`,
          resolvedPin,
          `session_${resolvedPin}`,
          resolvedSessionId,
          `session_${resolvedSessionId}`
        ];

        for (const ch of new Set(channels)) {
          if (ch) {
            io.to(ch).emit('session_status_update', payload);
            io.to(ch).emit('room_status_changed', payload);
            io.to(ch).emit('session_status_changed', payload);
          }
        }
      }
    } catch (_) {}

    // Automatically set history_status = 'completed' on parent quizizz_quizzes when game room is started/active
    if (finalStatus === 'active') {
      try {
        await pool.query("ALTER TABLE quizizz_quizzes ADD COLUMN history_status VARCHAR(50) DEFAULT NULL");
      } catch (_) {}
      try {
        const [sRows] = await pool.query('SELECT quiz_id FROM quizizz_game_sessions WHERE id = ? OR pin = ? UNION SELECT quiz_id FROM quizizz_sessions WHERE id = ?', [target, target, target]);
        const qId = sRows.length > 0 && sRows[0].quiz_id ? sRows[0].quiz_id : target;
        await pool.query("UPDATE quizizz_quizzes SET history_status = 'completed' WHERE id = ? OR id = ?", [qId, target]);
      } catch (_) {}
    }

    res.json({
      status: 'success',
      message: 'Status sesi diperbarui',
      status: finalStatus,
      session_status: finalStatus,
      is_active: finalStatus === 'active',
      is_started: finalStatus === 'active'
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

const handleStartSession = async (req, res) => {
  req.body = { ...req.body, status: 'active' };
  return handleUpdateSessionStatus(req, res);
};

router.patch('/sessions/:sessionId/status', handleUpdateSessionStatus);
router.patch('/sessions/pin/:pin/status', handleUpdateSessionStatus);
router.patch('/sessions/:pin/status', handleUpdateSessionStatus);
router.patch('/sessions/:sessionId/start', handleStartSession);
router.patch('/sessions/pin/:pin/start', handleStartSession);
router.post('/sessions/:sessionId/start', handleStartSession);

// 9c. Cari Sesi Via PIN / Code (Untuk Join Mahasiswa)
const handleGetSessionByCode = async (req, res) => {
  try {
    const code = (req.params.code || req.params.pin || req.params.id || '').trim();

    // Query session details from quizizz_game_sessions & quizizz_sessions
    const [rows] = await pool.query(
      `SELECT s.id, s.quiz_id, s.host_id, s.pin, s.mode, s.status, s.deadline, s.created_at, s.started_at,
              s.shuffle_questions, s.shuffle_answers,
              COALESCE(q.title, s.id) AS title, q.description
       FROM quizizz_game_sessions s 
       LEFT JOIN quizizz_quizzes q ON q.id = s.quiz_id 
       WHERE s.pin = ? OR s.id = ?
       UNION
       SELECT s.id, s.quiz_id, s.host_id, s.id AS pin, s.mode, s.status, s.deadline, s.created_at, NULL AS started_at,
              0 AS shuffle_questions, 0 AS shuffle_answers,
              COALESCE(q.title, s.title) AS title, COALESCE(q.description, s.description) AS description
       FROM quizizz_sessions s
       LEFT JOIN quizizz_quizzes q ON q.id = s.quiz_id
       WHERE s.id = ? OR s.quiz_id = ?`,
      [code, code, code, code]
    );

    if (rows.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan dengan kode PIN ini' });
    }

    const sessionData = rows[0];
    const isAnyActive = rows.some(r => r.status === 'active' || r.status === 'in_progress' || r.status === 'started');
    const currentStatus = isAnyActive ? 'active' : (sessionData.status || 'waiting');
    const isActive = isAnyActive || currentStatus === 'active';
    const startedAtRow = rows.find(r => r.started_at) || {};
    sessionData.started_at = startedAtRow.started_at ? new Date(startedAtRow.started_at).toISOString() : null;

    // Fetch isolated questions for this session, fallback to quiz questions if empty
    let [qRows] = await pool.query(
      'SELECT * FROM quizizz_questions WHERE quiz_id = ? ORDER BY order_index ASC',
      [sessionData.id]
    );
    if (qRows.length === 0 && sessionData.quiz_id !== sessionData.id) {
      const [parentQ] = await pool.query(
        'SELECT * FROM quizizz_questions WHERE quiz_id = ? ORDER BY order_index ASC',
        [sessionData.quiz_id]
      );
      qRows = parentQ;
    }

    const formattedQuestions = qRows.map(q => {
      let opts = [];
      if (q.options_json) {
        try {
          opts = typeof q.options_json === 'string' ? JSON.parse(q.options_json) : q.options_json;
        } catch (_) {}
      }
      if (!Array.isArray(opts) || opts.length === 0) {
        opts = [q.option_a, q.option_b, q.option_c, q.option_d].filter(o => o !== null && o !== undefined && o !== '');
      }

      // FITUR "Perbaikan Bug PG Disalahkan" (poin 6): array correct_list_json
      // dulu bisa "bocor" jadi nilai `correct` walau soalnya BUKAN
      // multi_select (misal data lama / edge case), sehingga perbandingan
      // teks di sisi mahasiswa (String vs List) selalu gagal cocok dan
      // soal selalu dianggap salah. Sekarang override array HANYA berlaku
      // untuk question_type multi_select. Default fallback juga diganti
      // dari huruf literal 'A' ke teks opsi pertama (kalau ada), supaya
      // tidak terjadi mismatch huruf vs teks opsi.
      let correctVal = q.correct_answer || (opts.length > 0 ? opts[0] : 'A');
      if (q.question_type === 'multi_select' && q.correct_list_json) {
        try {
          const parsed = typeof q.correct_list_json === 'string' ? JSON.parse(q.correct_list_json) : q.correct_list_json;
          if (Array.isArray(parsed) && parsed.length > 0) correctVal = parsed;
        } catch (_) {}
      }

      // FITUR "Gambar di Jawaban PG" (poin 5): parse gambar per-opsi
      // (kalau ada) supaya frontend bisa menampilkannya di samping teks
      // opsi jawaban.
      let optionImages = opts.map(() => null);
      if (q.option_images_json) {
        try {
          const parsedImgs = typeof q.option_images_json === 'string' ? JSON.parse(q.option_images_json) : q.option_images_json;
          if (Array.isArray(parsedImgs)) {
            optionImages = opts.map((_, i) => i < parsedImgs.length ? (parsedImgs[i] || null) : null);
          }
        } catch (_) {}
      }

      return {
        id: String(q.id),
        quiz_id: String(q.quiz_id),
        question: q.question_text,
        question_text: q.question_text,
        type: q.question_type || 'multiple_choice',
        question_type: q.question_type || 'multiple_choice',
        options: opts,
        options_json: opts,
        option_images: optionImages,
        correct: correctVal,
        correct_answer: correctVal,
        timer_seconds: q.timer_seconds || 30,
        image_url: q.image_url || null,
        order_index: q.order_index || 0,
        variable_calc_json: q.variable_calc_json || null
      };
    });

    res.json({
      status: 'success',
      session_type: 'quizizz_live',
      type: 'quizizz_live',
      session: {
        id: String(sessionData.id),
        quiz_id: String(sessionData.quiz_id),
        pin: String(sessionData.pin || code),
        session_code: String(sessionData.pin || code),
        title: sessionData.title || 'Live Host Gamifikasi',
        description: sessionData.description || '',
        status: currentStatus,
        session_status: currentStatus,
        is_active: isActive,
        is_started: isActive,
        mode: sessionData.mode || 'live',
        shuffle_questions: !!sessionData.shuffle_questions,
        shuffle_answers: !!sessionData.shuffle_answers,
        questions: formattedQuestions
      },
      questions: formattedQuestions
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/sessions/pin/:pin', handleGetSessionByCode);
router.get('/sessions/code/:code', handleGetSessionByCode);
router.get('/sessions/:id', handleGetSessionByCode);

// ============ 10. JOIN SESI ============
router.post('/sessions/:sessionId/join', async (req, res) => {
  try {
    const { display_name, user_id } = req.body;
    if (!display_name) return res.status(400).json({ status: 'gagal', message: 'display_name wajib diisi' });

    const [sessionRows] = await pool.query('SELECT status, mode FROM quizizz_game_sessions WHERE id = ?', [req.params.sessionId]);
    if (sessionRows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let userId = user_id || null;
    const authHeader = req.headers['authorization'];
    if (!userId && authHeader && authHeader.startsWith('Bearer ')) {
      try {
        const jwt = require('jsonwebtoken');
        const decoded = jwt.verify(authHeader.split(' ')[1], process.env.JWT_SECRET);
        userId = decoded.id;
      } catch (e) { /* anonim */ }
    }

    if (userId) {
      const [existing] = await pool.query(
        'SELECT id FROM quizizz_session_players WHERE session_id = ? AND user_id = ?',
        [req.params.sessionId, userId]
      );
      if (existing.length) {
        return res.status(200).json({ status: 'sukses', message: 'Re-joined', player_id: existing[0].id });
      }
    }

    const id = uuidv4();
    await pool.query(
      'INSERT INTO quizizz_session_players (id, session_id, user_id, display_name, score) VALUES (?, ?, ?, ?, 0)',
      [id, req.params.sessionId, userId, display_name]
    );

    res.status(201).json({ status: 'sukses', message: 'Berhasil join sesi', player_id: id });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 11. UBAH STATUS SESI ============
router.patch('/sessions/:sessionId/status', verifyToken, async (req, res) => {
  try {
    const { status } = req.body;
    if (!['waiting', 'in_progress', 'finished'].includes(status)) {
      return res.status(400).json({ status: 'gagal', message: 'status tidak valid' });
    }
    await pool.query('UPDATE quizizz_game_sessions SET status = ? WHERE id = ?', [status, req.params.sessionId]);
    res.json({ status: 'sukses', message: 'Status sesi diperbarui' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

function checkAnswerCorrectness(question, answer) {
  if (!question) return false;
  const qType = question.question_type || 'multiple_choice';

  if (qType === 'drawing' || qType === 'flashcard' || qType === 'word_cloud') {
    return true;
  }

  if (qType === 'multi_select') {
    let expected = [];
    if (question.correct_list_json) {
      try {
        const parsed = typeof question.correct_list_json === 'string' ? JSON.parse(question.correct_list_json) : question.correct_list_json;
        if (Array.isArray(parsed)) expected = parsed;
      } catch (_) {}
    }
    if (!expected.length && question.correct_answer) {
      try {
        const parsed = typeof question.correct_answer === 'string' ? JSON.parse(question.correct_answer) : question.correct_answer;
        if (Array.isArray(parsed)) expected = parsed;
        else expected = [String(question.correct_answer)];
      } catch (_) {
        expected = [String(question.correct_answer)];
      }
    }

    let given = [];
    if (Array.isArray(answer)) {
      given = answer;
    } else if (typeof answer === 'string') {
      try {
        const parsed = JSON.parse(answer);
        if (Array.isArray(parsed)) given = parsed;
        else given = answer.split(',').map(s => s.trim());
      } catch (_) {
        given = answer.split(',').map(s => s.trim());
      }
    }

    const normExp = expected.map(e => String(e).trim().toUpperCase()).sort();
    const normGiven = given.map(g => String(g).trim().toUpperCase()).sort();

    if (normExp.length === 0) return false;
    if (normExp.length !== normGiven.length) return false;
    return normExp.every((val, idx) => val === normGiven[idx]);
  }

  if (qType === 'short_answer') {
    return String(answer || '').trim().toLowerCase() === String(question.correct_answer || '').trim().toLowerCase();
  }

  const normAnswer = String(answer || '').trim().toUpperCase();
  const normCorrect = String(question.correct_answer || '').trim().toUpperCase();
  if (normAnswer === normCorrect) return true;

  // FITUR "Perbaikan Bug Jawaban PG Disalahkan Padahal Benar" (poin 6):
  // secara normal, jawaban yang dikirim mahasiswa (teks lengkap opsi,
  // misal "Jakarta") dibandingkan langsung dengan correct_answer (juga
  // teks lengkap opsi). Tapi kalau salah satu di antaranya ternyata
  // berupa HURUF opsi (A/B/C/D) -- misal karena data lama / jalur lain
  // yang mengirim huruf, bukan teks -- perbandingan literal di atas akan
  // SELALU gagal walau sebenarnya jawabannya benar. Sebagai pengaman,
  // coba juga cocokkan lewat resolusi huruf->teks opsi (dari option_a..d
  // / options_json) sebelum benar-benar memutuskan salah.
  if (/^[A-D]$/.test(normAnswer) || /^[A-D]$/.test(normCorrect)) {
    let opts = [question.option_a, question.option_b, question.option_c, question.option_d];
    if (question.options_json) {
      try {
        const parsedOpts = typeof question.options_json === 'string' ? JSON.parse(question.options_json) : question.options_json;
        if (Array.isArray(parsedOpts) && parsedOpts.length > 0) opts = parsedOpts;
      } catch (_) {}
    }
    const letterToText = (letter) => {
      const idx = 'ABCD'.indexOf(letter);
      if (idx < 0 || idx >= opts.length || opts[idx] === undefined || opts[idx] === null) return null;
      return String(opts[idx]).trim().toUpperCase();
    };
    const resolvedAnswer = /^[A-D]$/.test(normAnswer) ? letterToText(normAnswer) : normAnswer;
    const resolvedCorrect = /^[A-D]$/.test(normCorrect) ? letterToText(normCorrect) : normCorrect;
    if (resolvedAnswer !== null && resolvedCorrect !== null && resolvedAnswer === resolvedCorrect) return true;
  }

  return false;
}

// ============ 12. SUBMIT JAWABAN (SINGLE ATAU GENERAL SUBMISSION) ============
router.post('/sessions/:id/submit', async (req, res) => {
  try {
    const sessionId = req.params.id;
    const { player_id, student_id, student_name, question_id, answer, answers } = req.body;

    // Resolusi player_id
    let activePlayerId = player_id;
    if (!activePlayerId && (student_name || student_id)) {
      const name = student_name || `Mhs-${student_id}`;
      const [existing] = await pool.query(
        'SELECT id FROM quizizz_session_players WHERE session_id = ? AND (user_id = ? OR display_name = ?)',
        [sessionId, student_id || null, name]
      );
      if (existing.length) {
        activePlayerId = existing[0].id;
      } else {
        activePlayerId = uuidv4();
        await pool.query(
          'INSERT INTO quizizz_session_players (id, session_id, user_id, display_name, score) VALUES (?, ?, ?, ?, 0)',
          [activePlayerId, sessionId, student_id || null, name]
        );
      }
    }

    if (!activePlayerId) {
      return res.status(400).json({ status: 'gagal', message: 'player_id atau student_name wajib diisi' });
    }

    // Single Question Submit
    if (question_id && answer !== undefined) {
      const [qRows] = await pool.query('SELECT correct_answer, correct_list_json, question_type, option_a, option_b, option_c, option_d, options_json FROM quizizz_questions WHERE id = ?', [question_id]);
      const question = qRows[0] || {};
      const isCorrect = (req.body.is_correct !== undefined) ? (req.body.is_correct ? 1 : 0) : (checkAnswerCorrectness(question, answer) ? 1 : 0);

      const id = uuidv4();
      const ansStr = typeof answer === 'object' ? JSON.stringify(answer) : String(answer);
      await pool.query(
        'INSERT INTO quizizz_question_answers (id, session_id, question_id, player_id, answer_text, is_correct) VALUES (?, ?, ?, ?, ?, ?)',
        [id, sessionId, question_id, activePlayerId, ansStr, isCorrect]
      );

      let streak = 0;
      let multiplier = 1.0;
      let poinDidapat = 0;

      if (isCorrect) {
        const [prevAnswers] = await pool.query(
          'SELECT is_correct FROM quizizz_question_answers WHERE session_id = ? AND player_id = ? ORDER BY answered_at DESC LIMIT 10',
          [sessionId, activePlayerId]
        );
        for (const pa of prevAnswers) {
          if (pa.is_correct === 1) streak++;
          else break;
        }
        multiplier = Number((Math.min(1.0 + (streak * 0.1), 1.5)).toFixed(1));
        poinDidapat = Math.round(1000 * multiplier);
        await pool.query('UPDATE quizizz_session_players SET score = score + ? WHERE id = ?', [poinDidapat, activePlayerId]);
      }

      const [pRow] = await pool.query('SELECT score FROM quizizz_session_players WHERE id = ?', [activePlayerId]);
      const totalScore = pRow.length ? pRow[0].score : poinDidapat;

      return res.status(201).json({
        status: 'sukses',
        is_correct: isCorrect === 1,
        score: totalScore,
        poin_didapat: poinDidapat,
        streak,
        multiplier,
        player_id: activePlayerId
      });
    }

    // Batch Answers Array Submit
    if (Array.isArray(answers)) {
      let totalScore = 0;
      for (const item of answers) {
        const qId = item.question_id || item.id;
        const qAns = item.answer;
        if (!qId || qAns === undefined) continue;

        const [qRows] = await pool.query('SELECT correct_answer, correct_list_json, question_type, option_a, option_b, option_c, option_d, options_json FROM quizizz_questions WHERE id = ?', [qId]);
        const question = qRows[0] || {};
        const isCorrect = (item.is_correct !== undefined) ? (item.is_correct ? 1 : 0) : (checkAnswerCorrectness(question, qAns) ? 1 : 0);

        const id = uuidv4();
        const ansStr = typeof qAns === 'object' ? JSON.stringify(qAns) : String(qAns);
        await pool.query(
          'INSERT INTO quizizz_question_answers (id, session_id, question_id, player_id, answer_text, is_correct) VALUES (?, ?, ?, ?, ?, ?)',
          [id, sessionId, qId, activePlayerId, ansStr, isCorrect]
        );
        if (isCorrect) totalScore += 1000;
      }

      await pool.query('UPDATE quizizz_session_players SET score = score + ?, completed = 1 WHERE id = ?', [totalScore, activePlayerId]);
      return res.status(201).json({ status: 'sukses', score: totalScore, player_id: activePlayerId });
    }

    res.status(400).json({ status: 'gagal', message: 'Parameter jawaban (question_id & answer atau answers[]) wajib diisi' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

router.post('/sessions/:sessionId/questions/:questionId/answer', async (req, res) => {
  try {
    const { player_id, answer, time_remaining, total_time } = req.body;
    if (!player_id || answer === undefined) {
      return res.status(400).json({ status: 'gagal', message: 'player_id dan answer wajib diisi' });
    }

    const [qRows] = await pool.query('SELECT correct_answer, correct_list_json, question_type, option_a, option_b, option_c, option_d, options_json FROM quizizz_questions WHERE id = ?', [req.params.questionId]);
    if (qRows.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Soal tidak ditemukan' });
    }

    const question = qRows[0];
    const isCorrect = (req.body.is_correct !== undefined) ? (req.body.is_correct ? 1 : 0) : (checkAnswerCorrectness(question, answer) ? 1 : 0);

    const id = uuidv4();
    const ansStr = typeof answer === 'object' ? JSON.stringify(answer) : String(answer);
    await pool.query(
      'INSERT INTO quizizz_question_answers (id, session_id, question_id, player_id, answer_text, is_correct) VALUES (?, ?, ?, ?, ?, ?)',
      [id, req.params.sessionId, req.params.questionId, player_id, ansStr, isCorrect]
    );

    let streak = 0;
    let poinDidapat = 0;

    // PENTING: rumus poin di sini HARUS SAMA PERSIS dengan yang dipakai
    // Flutter (base 500 + bonus kecepatan hingga 500 + bonus 100 tiap
    // kelipatan 3 jawaban benar berturut-turut). Backend adalah SUMBER
    // KEBENARAN UTAMA untuk skor (dipakai Live Leaderboard & Podium), dan
    // Flutter sekarang memakai NILAI YANG DIKEMBALIKAN endpoint ini untuk
    // menampilkan skor ke mahasiswa — supaya "Total Skor Gamifikasi",
    // "Podium Juara", dan "Live Leaderboard" SELALU menunjukkan angka yang
    // sama persis (sebelumnya beda karena masing-masing pakai rumus sendiri).
    if (isCorrect) {
      const [prevAnswers] = await pool.query(
        'SELECT is_correct FROM quizizz_question_answers WHERE session_id = ? AND player_id = ? ORDER BY answered_at DESC LIMIT 20',
        [req.params.sessionId, player_id]
      );
      for (const pa of prevAnswers) {
        if (pa.is_correct === 1) streak++;
        else break;
      }

      const tTotal = Number(total_time) > 0 ? Number(total_time) : 30;
      let tRemaining = Number(time_remaining);
      if (isNaN(tRemaining)) tRemaining = 0;
      tRemaining = Math.max(0, Math.min(tRemaining, tTotal));
      const speedRatio = tRemaining / tTotal;
      const speedBonus = Math.round(500 * speedRatio);
      poinDidapat = 500 + speedBonus;

      if (streak > 0 && streak % 3 === 0) {
        poinDidapat += 100;
      }

      await pool.query('UPDATE quizizz_session_players SET score = score + ? WHERE id = ?', [poinDidapat, player_id]);
    }

    const [pRow] = await pool.query('SELECT score FROM quizizz_session_players WHERE id = ?', [player_id]);
    const totalScore = pRow.length ? pRow[0].score : poinDidapat;

    res.status(201).json({
      status: 'sukses',
      is_correct: isCorrect === 1,
      score: totalScore,
      poin_didapat: poinDidapat,
      streak
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 13. TANDAI PEMAIN SELESAI ============
router.post('/sessions/:sessionId/players/:playerId/complete', async (req, res) => {
  try {
    await pool.query('UPDATE quizizz_session_players SET completed = 1 WHERE id = ?', [req.params.playerId]);
    res.json({ status: 'sukses', message: 'Pemain selesai' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 14. LEADERBOARD SESI (DENGAN PODIUM TOP 3 🥇 🥈 🥉) ============
router.get('/sessions/:sessionId/leaderboard', async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT id, display_name, display_name as name, score, completed FROM quizizz_session_players WHERE session_id = ? ORDER BY score DESC',
      [req.params.sessionId]
    );

    const ranked = rows.map((r, idx) => ({
      rank: idx + 1,
      ...r
    }));

    const podium = {
      gold: ranked[0] || null,
      silver: ranked[1] || null,
      bronze: ranked[2] || null
    };

    res.json({ status: 'sukses', leaderboard: ranked, podium });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 15. ANALITIK MENDALAM (REPORTS) ============
router.get('/reports/:quizId', async (req, res) => {
  try {
    const { quizId } = req.params;
    const [questions] = await pool.query('SELECT * FROM quizizz_questions WHERE quiz_id = ? ORDER BY order_index', [quizId]);
    const [sessions] = await pool.query('SELECT * FROM quizizz_game_sessions WHERE quiz_id = ? ORDER BY created_at DESC', [quizId]);

    const sessionIds = sessions.map(s => s.id);
    let players = [];
    let answers = [];

    if (sessionIds.length) {
      const [pRows] = await pool.query('SELECT * FROM quizizz_session_players WHERE session_id IN (?)', [sessionIds]);
      const [aRows] = await pool.query('SELECT * FROM quizizz_question_answers WHERE session_id IN (?)', [sessionIds]);
      players = pRows;
      answers = aRows;
    }

    const questionStats = questions.map((q, idx) => {
      const qAnswers = answers.filter(a => a.question_id === q.id);
      const totalAnswers = qAnswers.length;
      const correctAnswers = qAnswers.filter(a => a.is_correct === 1).length;
      const accuracy = totalAnswers > 0 ? Math.round((correctAnswers / totalAnswers) * 100) : 0;
      return {
        question_index: idx,
        question_text: q.question_text,
        question_type: q.question_type,
        total_answers: totalAnswers,
        correct_answers: correctAnswers,
        accuracy_percent: accuracy,
      };
    });

    res.json({
      status: 'sukses',
      total_sessions: sessions.length,
      total_players: players.length,
      questions_count: questions.length,
      question_stats: questionStats,
      players: players.map(p => ({ id: p.id, display_name: p.display_name, score: p.score })),
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 17. LESSON MODE (PRESENTASI INTERAKTIF) ============

// 17a. Buat Lesson Baru
router.post('/lessons', verifyToken, async (req, res) => {
  try {
    const { title, description, slides, class_id } = req.body;
    if (!title) return res.status(400).json({ status: 'gagal', message: 'Judul lesson wajib diisi' });

    const id = uuidv4();
    const slidesJson = typeof slides === 'string' ? slides : JSON.stringify(slides || []);

    await pool.query(
      'INSERT INTO quizizz_lessons (id, dosen_id, title, description, slides_json, class_id) VALUES (?, ?, ?, ?, ?, ?)',
      [id, String(req.user.id), title, description || '', slidesJson, class_id || null]
    );

    res.status(201).json({
      status: 'sukses',
      message: 'Lesson berhasil dibuat',
      lesson: { id, title, description, class_id: class_id || null, slides: Array.isArray(slides) ? slides : JSON.parse(slidesJson) }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17b. Ambil Lesson Milik Dosen
// 17b2. Riwayat semua sesi live presentasi milik SATU lesson (fitur
// "Riwayat Presentasi" di Report) -- daftar setiap kali presentasi ini
// pernah dijalankan (live/ended), lengkap jumlah respon & pertanyaan Q&A.
router.get('/lessons/:id/sessions', verifyToken, async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT id, session_code, active_slide_index, status, responses_json, question_answers_json, qa_messages_json, created_at FROM quizizz_lesson_sessions WHERE lesson_id = ? ORDER BY created_at DESC',
      [req.params.id]
    );

    const sessions = rows.map(r => {
      let responseCount = 0, questionAnswerCount = 0, qaCount = 0;
      try { responseCount = (JSON.parse(r.responses_json || '[]') || []).length; } catch (_) {}
      try { questionAnswerCount = (JSON.parse(r.question_answers_json || '[]') || []).length; } catch (_) {}
      try { qaCount = (JSON.parse(r.qa_messages_json || '[]') || []).length; } catch (_) {}
      return {
        id: r.id,
        session_code: r.session_code,
        status: r.status,
        response_count: responseCount,
        question_answer_count: questionAnswerCount,
        qa_count: qaCount,
        created_at: r.created_at
      };
    });

    res.json({ status: 'sukses', sessions });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

router.get('/lessons/mine', verifyToken, async (req, res) => {
  try {
    const userId = String(req.user.id);
    // Fitur "Manajemen Kelas": filter presentasi berdasarkan class_id kalau
    // dikirim, sama seperti daftar kuis.
    const classId = req.query.class_id;
    const classFilter = classId ? 'AND class_id = ?' : 'AND class_id IS NULL';
    const params = classId ? [userId, classId] : [userId];
    const [rows] = await pool.query(
      `SELECT * FROM quizizz_lessons WHERE dosen_id = ? ${classFilter} ORDER BY created_at DESC`,
      params
    );

    const formatted = rows.map(r => ({
      ...r,
      slides: typeof r.slides_json === 'string' ? JSON.parse(r.slides_json || '[]') : r.slides_json
    }));

    res.json({ status: 'sukses', lessons: formatted });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17c. Hapus Lesson
router.delete('/lessons/:id', verifyToken, async (req, res) => {
  try {
    const lessonId = req.params.id;
    await pool.query('DELETE FROM quizizz_lesson_sessions WHERE lesson_id = ?', [lessonId]);
    await pool.query('DELETE FROM quizizz_lessons WHERE id = ?', [lessonId]);
    res.json({ status: 'sukses', message: 'Lesson berhasil dihapus' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17d. Memulai Sesi Live Lesson (status awal 'waiting' -- mahasiswa yang
// join akan menunggu di waiting room sampai dosen menekan "Start
// Presentation Now" yang mengubah status jadi 'live').
router.post('/lessons/:id/session', verifyToken, async (req, res) => {
  try {
    const lessonId = req.params.id;
    const [lessonRows] = await pool.query('SELECT * FROM quizizz_lessons WHERE id = ?', [lessonId]);
    if (lessonRows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Lesson tidak ditemukan' });

    const id = uuidv4();
    const sessionCode = generatePin();

    await pool.query(
      'INSERT INTO quizizz_lesson_sessions (id, lesson_id, session_code, active_slide_index, status, responses_json) VALUES (?, ?, ?, 0, ?, ?)',
      [id, lessonId, sessionCode, 'waiting', '[]']
    );

    res.status(201).json({
      status: 'sukses',
      message: 'Sesi live lesson dibuat',
      session: { id, lesson_id: lessonId, session_code: sessionCode, active_slide_index: 0, status: 'waiting' }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17e. Polling Mahasiswa (Get Live Session State by Code)
router.get('/lessons/session/code/:code', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const [rows] = await pool.query(
      `SELECT s.*, l.title, l.description, l.slides_json 
       FROM quizizz_lesson_sessions s
       JOIN quizizz_lessons l ON l.id = s.lesson_id
       WHERE s.session_code = ? OR s.id = ?`,
      [code, code]
    );

    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi lesson tidak ditemukan' });

    const sessionData = rows[0];
    let slides = [];
    try { slides = typeof sessionData.slides_json === 'string' ? JSON.parse(sessionData.slides_json) : sessionData.slides_json; } catch (_) {}
    let responses = [];
    try { responses = typeof sessionData.responses_json === 'string' ? JSON.parse(sessionData.responses_json || '[]') : (sessionData.responses_json || []); } catch (_) {}
    let activeQuestionIds = [];
    try { activeQuestionIds = JSON.parse(sessionData.active_question_ids || '[]') || []; } catch (_) {}
    let questionActivatedAt = {};
    try { questionActivatedAt = JSON.parse(sessionData.question_activated_at_json || '{}') || {}; } catch (_) {}
    let activatedHistory = [];
    try { activatedHistory = JSON.parse(sessionData.activated_history_json || '[]') || []; } catch (_) {}

    res.json({
      status: 'sukses',
      session: {
        id: sessionData.id,
        lesson_id: sessionData.lesson_id,
        session_code: sessionData.session_code,
        active_slide_index: sessionData.active_slide_index,
        status: sessionData.status,
        // PENTING (poin 2, 3, 4): active_question_ids (BUKAN lagi tunggal)
        // dipoll mahasiswa untuk tahu soal MANA SAJA (maks 2) yang sedang
        // diaktifkan dosen saat ini. question_activated_at dipakai
        // menghitung timer mundur per soal. activated_history dipakai
        // indikator "Sudah Digunakan" di bank soal dosen. status == 'ended'
        // dipakai frontend untuk otomatis mengeluarkan mahasiswa dari
        // presentasi saat dosen menekan tombol "Akhiri Presentasi".
        active_question_id: sessionData.active_question_id || null,
        active_question_ids: activeQuestionIds,
        question_activated_at: questionActivatedAt,
        activated_history: activatedHistory,
        responses
      },
      lesson: {
        title: sessionData.title,
        description: sessionData.description,
        slides
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17f. Dosen Mengontrol Slide (Next / Prev / State)
router.patch('/lessons/session/:code/state', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const { active_slide_index, status } = req.body;

    if (active_slide_index !== undefined) {
      await pool.query(
        'UPDATE quizizz_lesson_sessions SET active_slide_index = ? WHERE session_code = ? OR id = ?',
        [parseInt(active_slide_index), code, code]
      );
    }

    if (status !== undefined) {
      await pool.query(
        'UPDATE quizizz_lesson_sessions SET status = ? WHERE session_code = ? OR id = ?',
        [status, code, code]
      );
    }

    res.json({ status: 'sukses', message: 'State slide diperbarui', active_slide_index: parseInt(active_slide_index || 0) });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17g. Mahasiswa Mengirim Respon Per Slide
router.post('/lessons/session/:code/respond', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const { slide_index, student_name, student_id, answer } = req.body;

    const [rows] = await pool.query(
      'SELECT id, responses_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );

    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi lesson tidak ditemukan' });

    const sessionObj = rows[0];
    let responsesList = [];
    try { responsesList = typeof sessionObj.responses_json === 'string' ? JSON.parse(sessionObj.responses_json || '[]') : (sessionObj.responses_json || []); } catch (_) {}

    const newResponse = {
      id: uuidv4(),
      slide_index: slide_index !== undefined ? parseInt(slide_index) : 0,
      student_name: student_name || 'Mahasiswa Anonim',
      student_id: student_id || null,
      answer,
      responded_at: new Date().toISOString()
    };

    responsesList.push(newResponse);

    await pool.query(
      'UPDATE quizizz_lesson_sessions SET responses_json = ? WHERE id = ?',
      [JSON.stringify(responsesList), sessionObj.id]
    );

    res.status(201).json({ status: 'sukses', message: 'Respon berhasil dikirim', response: newResponse });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17h. Dosen Polling Respon Jawaban Live
router.get('/lessons/session/:code/responses', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const [rows] = await pool.query(
      'SELECT active_slide_index, responses_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );

    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi lesson tidak ditemukan' });

    let responses = [];
    try { responses = typeof rows[0].responses_json === 'string' ? JSON.parse(rows[0].responses_json || '[]') : (rows[0].responses_json || []); } catch (_) {}

    res.json({
      status: 'sukses',
      active_slide_index: rows[0].active_slide_index,
      responses
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ FITUR "KELOLA SOAL PRESENTASI" (poin 2) ============

// 17i. Dosen: Buat soal baru untuk sebuah presentasi (disimpan di bank
// soal presentasi tsb, TERPISAH dari daftar slide -- baru ditampilkan ke
// mahasiswa kalau dosen "aktifkan" saat presentasi berlangsung).
router.post('/lessons/:id/questions', verifyToken, async (req, res) => {
  try {
    const lessonId = req.params.id;
    const { question_text, options, correct_answer, order_index, question_type, time_limit_seconds, image_url, option_images } = req.body;
    if (!question_text) return res.status(400).json({ status: 'gagal', message: 'Teks soal wajib diisi' });

    const type = question_type || 'multiple_choice';
    // Untuk tipe "benar/salah", opsi selalu dipaksa ['Benar', 'Salah']
    // supaya konsisten, tidak bergantung input opsi dari dosen.
    const finalOptions = type === 'true_false' ? ['Benar', 'Salah'] : (options || []);
    // Fitur "Timer Soal Presentasi": batas waktu detik, default 30, boleh
    // null (tanpa batas waktu) kalau dosen kirim 0/null eksplisit.
    const timeLimit = time_limit_seconds === null ? null : (parseInt(time_limit_seconds ?? 30) || 30);
    // FITUR "Gambar di Soal & Jawaban Presentasi" (poin 4): gambar
    // pertanyaan (opsional) & gambar per-opsi jawaban (opsional, array
    // sejajar index dengan finalOptions -- dipotong/di-pad supaya panjangnya
    // selalu sama dengan jumlah opsi).
    const finalImageUrl = (image_url && image_url.toString().trim().length > 0) ? image_url : null;
    const rawOptionImages = Array.isArray(option_images) ? option_images : [];
    const finalOptionImages = finalOptions.map((_, i) => (rawOptionImages[i] && rawOptionImages[i].toString().trim().length > 0) ? rawOptionImages[i] : null);
    const hasAnyOptionImage = finalOptionImages.some(v => v !== null);

    const id = uuidv4();
    await pool.query(
      'INSERT INTO quizizz_lesson_questions (id, lesson_id, question_text, options_json, correct_answer, order_index, question_type, time_limit_seconds, image_url, option_images_json, variable_calc_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [id, lessonId, question_text, JSON.stringify(finalOptions), correct_answer || null, parseInt(order_index || 0), type, timeLimit, finalImageUrl, hasAnyOptionImage ? JSON.stringify(finalOptionImages) : null, req.body.variable_calc_json || null]
    );

    res.status(201).json({
      status: 'sukses',
      message: 'Soal berhasil ditambahkan',
      question: {
        id, lesson_id: lessonId, question_text, options: finalOptions, correct_answer: correct_answer || null,
        question_type: type, time_limit_seconds: timeLimit, image_url: finalImageUrl,
        option_images: hasAnyOptionImage ? finalOptionImages : finalOptions.map(() => null),
        variable_calc_json: req.body.variable_calc_json || null,
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// FITUR "Edit Soal Presentasi" (poin 4): update soal yang sudah ada
// (teks pertanyaan, opsi, jawaban benar, gambar pertanyaan & per-opsi,
// tipe soal, timer) tanpa perlu hapus lalu buat ulang.
router.put('/lessons/questions/:questionId', verifyToken, async (req, res) => {
  try {
    const { questionId } = req.params;
    const { question_text, options, correct_answer, question_type, time_limit_seconds, image_url, option_images } = req.body;
    if (!question_text) return res.status(400).json({ status: 'gagal', message: 'Teks soal wajib diisi' });

    const type = question_type || 'multiple_choice';
    const finalOptions = type === 'true_false' ? ['Benar', 'Salah'] : (options || []);
    const timeLimit = time_limit_seconds === null ? null : (parseInt(time_limit_seconds ?? 30) || 30);
    const finalImageUrl = (image_url && image_url.toString().trim().length > 0) ? image_url : null;
    const rawOptionImages = Array.isArray(option_images) ? option_images : [];
    const finalOptionImages = finalOptions.map((_, i) => (rawOptionImages[i] && rawOptionImages[i].toString().trim().length > 0) ? rawOptionImages[i] : null);
    const hasAnyOptionImage = finalOptionImages.some(v => v !== null);

    const [result] = await pool.query(
      'UPDATE quizizz_lesson_questions SET question_text = ?, options_json = ?, correct_answer = ?, question_type = ?, time_limit_seconds = ?, image_url = ?, option_images_json = ?, variable_calc_json = ? WHERE id = ?',
      [question_text, JSON.stringify(finalOptions), correct_answer || null, type, timeLimit, finalImageUrl, hasAnyOptionImage ? JSON.stringify(finalOptionImages) : null, req.body.variable_calc_json || null, questionId]
    );
    if (result.affectedRows === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Soal tidak ditemukan' });
    }

    res.json({
      status: 'sukses',
      message: 'Soal berhasil diperbarui',
      question: {
        id: questionId, question_text, options: finalOptions, correct_answer: correct_answer || null,
        question_type: type, time_limit_seconds: timeLimit, image_url: finalImageUrl,
        option_images: hasAnyOptionImage ? finalOptionImages : finalOptions.map(() => null),
        variable_calc_json: req.body.variable_calc_json || null,
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17j. Daftar soal milik sebuah presentasi (untuk halaman "Kelola Soal"
// dosen, dan juga dipakai mahasiswa untuk menampilkan soal aktif).
router.get('/lessons/:id/questions', async (req, res) => {
  try {
    const [rows] = await pool.query(
      'SELECT * FROM quizizz_lesson_questions WHERE lesson_id = ? ORDER BY order_index ASC, created_at ASC',
      [req.params.id]
    );
    const questions = rows.map(r => {
      const options = (() => { try { return JSON.parse(r.options_json || '[]'); } catch (_) { return []; } })();
      const optionImages = (() => { try { return JSON.parse(r.option_images_json || 'null'); } catch (_) { return null; } })();
      return {
        ...r,
        options,
        option_images: Array.isArray(optionImages) ? optionImages : options.map(() => null),
      };
    });
    res.json({ status: 'sukses', questions });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17k. Hapus soal dari bank soal presentasi.
router.delete('/lessons/questions/:qId', verifyToken, async (req, res) => {
  try {
    await pool.query('DELETE FROM quizizz_lesson_questions WHERE id = ?', [req.params.qId]);
    res.json({ status: 'sukses', message: 'Soal berhasil dihapus' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17l. Dosen: AKTIFKAN salah satu soal dari bank soal saat presentasi
// sedang live -- mahasiswa yang sedang polling sesi ini akan otomatis
// melihat soal ini muncul dan bisa langsung menjawab (konsep gamifikasi
// digabung dengan presentasi, mirip Mentimeter/Kahoot).
// PENTING (perbaikan bug "Tandai Dijawab" & "Aktifkan Soal" tidak berfungsi):
// endpoint di bawah ini SENGAJA dibuat publik (tanpa verifyToken), sama
// seperti endpoint sesi presentasi lainnya (state, submit, ask, qa) --
// karena semuanya diakses lewat kode sesi (session code) yang hanya
// diketahui dosen & mahasiswa yang sudah bergabung, bukan lewat login user.
// Sebelumnya endpoint ini mewajibkan verifyToken padahal Flutter selalu
// memanggilnya TANPA token (withAuth: false), sehingga selalu ditolak
// (401) secara diam-diam dan terlihat seperti "tidak berfungsi".
//
// Fitur "Aktifkan hingga 2 soal sekaligus" + "Timer soal": mendukung
// MAKSIMAL 2 soal aktif bersamaan (active_question_ids, bukan lagi 1 soal
// tunggal), mencatat waktu aktivasi tiap soal (buat timer mundur), dan
// menambahkan soal ke riwayat "pernah diaktifkan" (buat indikator "Sudah
// Digunakan" di bank soal).
router.patch('/lessons/session/:code/activate-question', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const { question_id } = req.body;
    if (!question_id) return res.status(400).json({ status: 'gagal', message: 'question_id wajib diisi' });

    const [rows] = await pool.query(
      'SELECT id, active_question_ids, question_activated_at_json, activated_history_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let activeIds = [];
    try { activeIds = JSON.parse(rows[0].active_question_ids || '[]') || []; } catch (_) {}
    let activatedAt = {};
    try { activatedAt = JSON.parse(rows[0].question_activated_at_json || '{}') || {}; } catch (_) {}
    let history = [];
    try { history = JSON.parse(rows[0].activated_history_json || '[]') || []; } catch (_) {}

    if (!activeIds.includes(question_id)) {
      if (activeIds.length >= 2) {
        return res.status(400).json({ status: 'gagal', message: 'Maksimal 2 soal aktif bersamaan. Nonaktifkan salah satu dulu.' });
      }
      activeIds.push(question_id);
    }
    activatedAt[question_id] = new Date().toISOString();
    if (!history.includes(question_id)) history.push(question_id);

    await pool.query(
      'UPDATE quizizz_lesson_sessions SET active_question_id = ?, active_question_ids = ?, question_activated_at_json = ?, activated_history_json = ? WHERE id = ?',
      [activeIds[0] || null, JSON.stringify(activeIds), JSON.stringify(activatedAt), JSON.stringify(history), rows[0].id]
    );
    res.json({ status: 'sukses', message: 'Soal berhasil diaktifkan', active_question_ids: activeIds });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17m. Dosen: NONAKTIFKAN salah satu soal yang sedang aktif (menyembunyikan
// soal itu saja dari layar mahasiswa, soal aktif lainnya tetap tampil).
router.patch('/lessons/session/:code/deactivate-question', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const { question_id } = req.body;

    const [rows] = await pool.query(
      'SELECT id, active_question_ids FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let activeIds = [];
    try { activeIds = JSON.parse(rows[0].active_question_ids || '[]') || []; } catch (_) {}
    // Kalau question_id tidak dikirim (kompatibilitas lama), nonaktifkan SEMUA.
    activeIds = question_id ? activeIds.filter(id => id !== question_id) : [];

    await pool.query(
      'UPDATE quizizz_lesson_sessions SET active_question_id = ?, active_question_ids = ? WHERE id = ?',
      [activeIds[0] || null, JSON.stringify(activeIds), rows[0].id]
    );
    res.json({ status: 'sukses', message: 'Soal berhasil dinonaktifkan', active_question_ids: activeIds });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17n. Mahasiswa: jawab soal yang sedang aktif secara langsung.
router.post('/lessons/session/:code/answer-question', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const { question_id, student_name, student_id, answer } = req.body;
    if (!question_id) return res.status(400).json({ status: 'gagal', message: 'question_id wajib diisi' });

    const [sessRows] = await pool.query(
      'SELECT id, question_answers_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (sessRows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    const [qRows] = await pool.query('SELECT correct_answer, question_type FROM quizizz_lesson_questions WHERE id = ?', [question_id]);
    const correctAnswer = qRows.length > 0 ? qRows[0].correct_answer : null;
    const qType = qRows.length > 0 ? (qRows[0].question_type || 'multiple_choice') : 'multiple_choice';

    // PENTING (dukungan tipe soal Multi-Select & Jawaban Singkat):
    // - multi_select: cocokkan sebagai KUMPULAN huruf (urutan pilih tidak
    //   masalah, "A,C" sama saja dengan "C,A").
    // - short_answer & lainnya: cocokkan sebagai teks (tidak peka huruf
    //   besar/kecil, spasi awal-akhir diabaikan).
    let isCorrect = false;
    if (req.body.is_correct !== undefined) {
      isCorrect = req.body.is_correct === true || req.body.is_correct === 1 || req.body.is_correct === 'true';
    } else if (correctAnswer != null) {
      if (qType === 'multi_select') {
        const norm = (s) => String(s).split(',').map(x => x.trim().toUpperCase()).filter(Boolean).sort().join(',');
        isCorrect = norm(answer) === norm(correctAnswer);
      } else {
        isCorrect = String(answer).trim().toUpperCase() === String(correctAnswer).trim().toUpperCase();
      }
    }

    let answersList = [];
    try { answersList = typeof sessRows[0].question_answers_json === 'string' ? JSON.parse(sessRows[0].question_answers_json || '[]') : (sessRows[0].question_answers_json || []); } catch (_) {}

    // Satu mahasiswa hanya boleh menjawab SEKALI per soal aktif -- kalau
    // sudah pernah jawab soal yang sama, ganti jawabannya (bukan dobel).
    const existingIdx = answersList.findIndex(a => a.question_id === question_id && (a.student_id === student_id || a.student_name === student_name));
    const newAnswer = {
      id: uuidv4(),
      question_id,
      student_name: student_name || 'Mahasiswa Anonim',
      student_id: student_id || null,
      answer,
      is_correct: isCorrect,
      answered_at: new Date().toISOString()
    };
    if (existingIdx >= 0) answersList[existingIdx] = newAnswer; else answersList.push(newAnswer);

    await pool.query('UPDATE quizizz_lesson_sessions SET question_answers_json = ? WHERE id = ?', [JSON.stringify(answersList), sessRows[0].id]);

    res.status(201).json({ status: 'sukses', message: 'Jawaban terkirim', is_correct: isCorrect });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17o. Dosen: lihat hasil live jawaban untuk soal yang sedang/pernah aktif
// di sesi ini (jumlah per pilihan jawaban + daftar mahasiswa yang sudah
// menjawab, untuk ditampilkan real-time mirip papan skor gamifikasi).
router.get('/lessons/session/:code/question-results', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const questionId = req.query.question_id;
    const [rows] = await pool.query(
      'SELECT question_answers_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let allAnswers = [];
    try { allAnswers = typeof rows[0].question_answers_json === 'string' ? JSON.parse(rows[0].question_answers_json || '[]') : (rows[0].question_answers_json || []); } catch (_) {}

    const filtered = questionId ? allAnswers.filter(a => a.question_id === questionId) : allAnswers;
    const tally = {};
    let correctCount = 0;
    for (const a of filtered) {
      const key = String(a.answer);
      tally[key] = (tally[key] || 0) + 1;
      if (a.is_correct) correctCount += 1;
    }

    res.json({ status: 'sukses', total_answers: filtered.length, correct_count: correctCount, tally, answers: filtered });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17o2. HASIL AKHIR SESI PRESENTASI (fitur "hasil nilai quiz presentasi
// muncul saat sesi berakhir"): rekap skor SEMUA mahasiswa dari SELURUH soal
// interaktif yang pernah diaktifkan sepanjang sesi ini, diurutkan seperti
// papan peringkat (leaderboard) -- ditampilkan ke dosen & mahasiswa begitu
// dosen menekan "Akhiri Presentasi".
router.get('/lessons/session/:code/final-results', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const [rows] = await pool.query(
      'SELECT question_answers_json, activated_history_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let allAnswers = [];
    try { allAnswers = JSON.parse(rows[0].question_answers_json || '[]') || []; } catch (_) {}
    let totalQuestionsAsked = 0;
    try { totalQuestionsAsked = (JSON.parse(rows[0].activated_history_json || '[]') || []).length; } catch (_) {}

    // FITUR "Riwayat Jawaban Mahasiswa di Presentasi" (poin 4): ambil detail
    // tiap soal (teks pertanyaan & jawaban benarnya) supaya bisa ditampilkan
    // per-mahasiswa, sama seperti fitur Riwayat Jawaban di PR/Kuis Gamifikasi.
    const questionIds = [...new Set(allAnswers.map(a => a.question_id).filter(Boolean))];
    const questionMap = {};
    if (questionIds.length > 0) {
      const placeholders = questionIds.map(() => '?').join(',');
      const [qRows] = await pool.query(
        `SELECT id, question_text, correct_answer, options_json, question_type FROM quizizz_lesson_questions WHERE id IN (${placeholders})`,
        questionIds
      );
      for (const q of qRows) {
        questionMap[q.id] = q;
      }
    }

    // Rekap per mahasiswa: total soal dijawab, total jawaban benar, dan
    // rincian jawaban tiap soal (untuk dialog "Riwayat Jawaban").
    const perStudent = {};
    for (const a of allAnswers) {
      const key = a.student_id || a.student_name || 'anonim';
      if (!perStudent[key]) {
        perStudent[key] = { student_name: a.student_name || 'Mahasiswa Anonim', student_id: a.student_id || null, answered: 0, correct: 0, answers: [] };
      }
      perStudent[key].answered += 1;
      if (a.is_correct) perStudent[key].correct += 1;

      const qInfo = questionMap[a.question_id];
      let correctAnswerDisplay = qInfo ? qInfo.correct_answer : null;
      // Untuk multi_select, ubah huruf jadi teks opsi lengkap supaya lebih
      // mudah dibaca dosen di riwayat (mis. "A,C" -> "Opsi A, Opsi C").
      if (qInfo && qInfo.question_type === 'multi_select' && qInfo.options_json && correctAnswerDisplay) {
        try {
          const opts = typeof qInfo.options_json === 'string' ? JSON.parse(qInfo.options_json) : qInfo.options_json;
          const letters = String(correctAnswerDisplay).split(',').map(s => s.trim()).filter(Boolean);
          correctAnswerDisplay = letters.map(l => {
            const idx = 'ABCD'.indexOf(l.toUpperCase());
            return (idx >= 0 && opts[idx] !== undefined) ? opts[idx] : l;
          }).join(', ');
        } catch (_) {}
      }
      let studentAnswerDisplay = a.answer;
      if (qInfo && qInfo.question_type === 'multi_select' && qInfo.options_json && studentAnswerDisplay) {
        try {
          const opts = typeof qInfo.options_json === 'string' ? JSON.parse(qInfo.options_json) : qInfo.options_json;
          const letters = String(studentAnswerDisplay).split(',').map(s => s.trim()).filter(Boolean);
          studentAnswerDisplay = letters.map(l => {
            const idx = 'ABCD'.indexOf(l.toUpperCase());
            return (idx >= 0 && opts[idx] !== undefined) ? opts[idx] : l;
          }).join(', ');
        } catch (_) {}
      }

      perStudent[key].answers.push({
        question: qInfo ? qInfo.question_text : 'Soal tidak ditemukan',
        student_answer: studentAnswerDisplay,
        correct_answer: correctAnswerDisplay,
        is_correct: !!a.is_correct,
      });
    }

    const leaderboard = Object.values(perStudent).sort((a, b) => b.correct - a.correct || b.answered - a.answered);

    res.json({
      status: 'sukses',
      total_questions_asked: totalQuestionsAsked,
      total_students_participated: leaderboard.length,
      leaderboard
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ FITUR "TANYA-JAWAB LIVE" (poin 3) ============

// 17p. Mahasiswa: mengajukan pertanyaan bebas selama presentasi
// berlangsung -- muncul di halaman mahasiswa & dosen (mirip kolom chat Q&A
// pada Zoom/Google Meet, tapi terintegrasi dalam presentasi).
router.post('/lessons/session/:code/ask', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const { student_name, student_id, message, sender_name, sender_id, sender_role, is_private, to_user_id, to_user_name } = req.body;
    if (!message || !message.trim()) return res.status(400).json({ status: 'gagal', message: 'Pesan tidak boleh kosong' });

    const [rows] = await pool.query(
      'SELECT id, qa_messages_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let qaList = [];
    try { qaList = typeof rows[0].qa_messages_json === 'string' ? JSON.parse(rows[0].qa_messages_json || '[]') : (rows[0].qa_messages_json || []); } catch (_) {}

    const sName = sender_name || student_name || 'Anonim';
    const sId = sender_id || student_id || null;
    const sRole = sender_role || 'student';
    const isPriv = is_private === true || is_private === 'true';

    const newQuestion = {
      id: uuidv4(),
      student_name: sName, // backwards compatibility
      student_id: sId,
      sender_name: sName,
      sender_id: sId,
      sender_role: sRole,
      message: message.trim(),
      is_private: isPriv,
      to_user_id: to_user_id || null,
      to_user_name: to_user_name || null,
      answered: false,
      asked_at: new Date().toISOString(), // backwards compatibility
      created_at: new Date().toISOString(),
      replies: []
    };
    qaList.push(newQuestion);

    await pool.query('UPDATE quizizz_lesson_sessions SET qa_messages_json = ? WHERE id = ?', [JSON.stringify(qaList), rows[0].id]);

    res.status(201).json({ status: 'sukses', message: 'Pesan terkirim', question: newQuestion });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17q. Ambil semua pertanyaan Q&A di sesi ini (dipoll dosen & mahasiswa).
router.get('/lessons/session/:code/qa', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const [rows] = await pool.query(
      'SELECT qa_messages_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let qaList = [];
    try { qaList = typeof rows[0].qa_messages_json === 'string' ? JSON.parse(rows[0].qa_messages_json || '[]') : (rows[0].qa_messages_json || []); } catch (_) {}
    qaList.sort((a, b) => new Date(b.asked_at) - new Date(a.asked_at));

    res.json({ status: 'sukses', questions: qaList });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17r. Dosen: tandai pertanyaan Q&A sudah dijawab (opsional, penanda visual
// supaya dosen tahu pertanyaan mana yang sudah dibahas).
router.patch('/lessons/session/:code/qa/:qId/mark-answered', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const [rows] = await pool.query(
      'SELECT id, qa_messages_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let qaList = [];
    try { qaList = typeof rows[0].qa_messages_json === 'string' ? JSON.parse(rows[0].qa_messages_json || '[]') : (rows[0].qa_messages_json || []); } catch (_) {}
    qaList = qaList.map(q => q.id === req.params.qId ? { ...q, answered: true } : q);

    await pool.query('UPDATE quizizz_lesson_sessions SET qa_messages_json = ? WHERE id = ?', [JSON.stringify(qaList), rows[0].id]);
    res.json({ status: 'sukses', message: 'Pertanyaan ditandai sudah dijawab' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 17s. Dosen: BALAS pertanyaan mahasiswa secara langsung (bukan cuma
// menandai "sudah dijawab") -- balasan tersimpan bersama pertanyaan dan
// otomatis muncul di layar mahasiswa yang bertanya (dan mahasiswa lain).
router.post('/lessons/session/:code/qa/:qId/reply', async (req, res) => {
  try {
    const code = req.params.code.trim();
    const { reply, sender_name, sender_id, sender_role } = req.body;
    if (!reply || !reply.trim()) return res.status(400).json({ status: 'gagal', message: 'Balasan tidak boleh kosong' });

    const [rows] = await pool.query(
      'SELECT id, qa_messages_json FROM quizizz_lesson_sessions WHERE session_code = ? OR id = ?',
      [code, code]
    );
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Sesi tidak ditemukan' });

    let qaList = [];
    try { qaList = typeof rows[0].qa_messages_json === 'string' ? JSON.parse(rows[0].qa_messages_json || '[]') : (rows[0].qa_messages_json || []); } catch (_) {}
    
    const sName = sender_name || 'Dosen';
    const sId = sender_id || null;
    const sRole = sender_role || 'teacher';
    
    qaList = qaList.map(q => {
      if (q.id === req.params.qId) {
        const newReply = {
          id: uuidv4(),
          sender_name: sName,
          sender_id: sId,
          sender_role: sRole,
          message: reply.trim(),
          created_at: new Date().toISOString()
        };
        let replies = Array.isArray(q.replies) ? [...q.replies] : [];
        if (replies.length === 0 && q.reply) {
          replies.push({
            id: uuidv4(),
            sender_name: 'Dosen',
            sender_role: 'teacher',
            message: q.reply,
            created_at: q.replied_at || new Date().toISOString()
          });
        }
        replies.push(newReply);
        return { 
          ...q, 
          answered: true, 
          reply: reply.trim(), // backwards compatibility
          replied_at: new Date().toISOString(),
          replies 
        };
      }
      return q;
    });

    await pool.query('UPDATE quizizz_lesson_sessions SET qa_messages_json = ? WHERE id = ?', [JSON.stringify(qaList), rows[0].id]);
    res.json({ status: 'sukses', message: 'Balasan terkirim' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 18. FLASHCARDS BELAJAR ============

// 18a. Buat Set Flashcard
router.post('/flashcards', verifyToken, async (req, res) => {
  try {
    const { title, subject, is_public, cards, class_id } = req.body;
    if (!title) return res.status(400).json({ status: 'gagal', message: 'Judul flashcard wajib diisi' });

    const id = uuidv4();
    const code = generatePin();
    const cardsJson = typeof cards === 'string' ? cards : JSON.stringify(cards || []);

    await pool.query(
      'INSERT INTO quizizz_flashcards (id, dosen_id, code, title, subject, cards_json, is_public, class_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, String(req.user.id), code, title, subject || 'Umum', cardsJson, is_public !== undefined ? (is_public ? 1 : 0) : 1, class_id || null]
    );

    res.status(201).json({
      status: 'sukses',
      message: 'Set flashcard berhasil dibuat',
      flashcard: { id, code, title, subject: subject || 'Umum', is_public: is_public !== false, class_id: class_id || null, cards: Array.isArray(cards) ? cards : JSON.parse(cardsJson) }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 18b. Ambil Daftar Flashcard
router.get('/flashcards', async (req, res) => {
  try {
    let userId = null;
    const authHeader = req.headers['authorization'];
    if (authHeader && authHeader.startsWith('Bearer ')) {
      try {
        const jwt = require('jsonwebtoken');
        const decoded = jwt.verify(authHeader.split(' ')[1], process.env.JWT_SECRET);
        userId = String(decoded.id);
      } catch (e) {}
    }

    // Fitur "Manajemen Kelas": kalau class_id dikirim, tampilkan HANYA
    // flashcard yang dibuat dalam kelas tersebut (supaya tidak tercampur
    // dengan kelas lain). Kalau tidak dikirim, pakai perilaku lama
    // (flashcard publik + milik sendiri, lintas-kelas / tanpa kelas).
    const classId = req.query.class_id;
    let query;
    let params;
    if (classId) {
      query = 'SELECT * FROM quizizz_flashcards WHERE class_id = ?';
      params = [classId];
    } else if (userId) {
      query = 'SELECT * FROM quizizz_flashcards WHERE (is_public = 1 OR dosen_id = ?) AND class_id IS NULL';
      params = [userId];
    } else {
      query = 'SELECT * FROM quizizz_flashcards WHERE is_public = 1 AND class_id IS NULL';
      params = [];
    }
    query += ' ORDER BY created_at DESC';

    const [rows] = await pool.query(query, params);
    const formatted = rows.map(r => ({
      ...r,
      cards: typeof r.cards_json === 'string' ? JSON.parse(r.cards_json || '[]') : r.cards_json
    }));

    res.json({ status: 'sukses', flashcards: formatted });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }

});

// 18c. Ambil Detail Flashcard Tunggal
router.get('/flashcards/:id', async (req, res) => {
  try {
    const id = req.params.id;
    const [rows] = await pool.query(
      'SELECT * FROM quizizz_flashcards WHERE id = ? OR code = ?',
      [id, id]
    );

    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Set flashcard tidak ditemukan' });

    const flashcard = rows[0];
    flashcard.cards = typeof flashcard.cards_json === 'string' ? JSON.parse(flashcard.cards_json || '[]') : flashcard.cards_json;

    res.json({ status: 'sukses', flashcard });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 18d. Update Set Flashcard
router.put('/flashcards/:id', verifyToken, async (req, res) => {
  try {
    const id = req.params.id;
    const { title, subject, is_public, cards } = req.body;

    const cardsJson = cards ? (typeof cards === 'string' ? cards : JSON.stringify(cards)) : null;

    let updates = [];
    let params = [];
    if (title !== undefined) { updates.push('title = ?'); params.push(title); }
    if (subject !== undefined) { updates.push('subject = ?'); params.push(subject); }
    if (is_public !== undefined) { updates.push('is_public = ?'); params.push(is_public ? 1 : 0); }
    if (cardsJson) { updates.push('cards_json = ?'); params.push(cardsJson); }

    if (updates.length === 0) {
      return res.status(400).json({ status: 'gagal', message: 'Tidak ada data untuk diperbarui' });
    }

    params.push(id);
    await pool.query(`UPDATE quizizz_flashcards SET ${updates.join(', ')} WHERE id = ?`, params);

    res.json({ status: 'sukses', message: 'Set flashcard berhasil diperbarui' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 18e. Hapus Set Flashcard
router.delete('/flashcards/:id', verifyToken, async (req, res) => {
  try {
    const id = req.params.id;
    await pool.query('DELETE FROM quizizz_flashcard_progress WHERE flashcard_id = ?', [id]);
    await pool.query('DELETE FROM quizizz_flashcards WHERE id = ?', [id]);
    res.json({ status: 'sukses', message: 'Set flashcard berhasil dihapus' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 18f. Duplikasi Set Flashcard
router.post('/flashcards/:id/duplicate', verifyToken, async (req, res) => {
  try {
    const id = req.params.id;
    const [rows] = await pool.query('SELECT * FROM quizizz_flashcards WHERE id = ?', [id]);
    if (rows.length === 0) return res.status(404).json({ status: 'gagal', message: 'Set flashcard tidak ditemukan' });

    const orig = rows[0];
    const newId = uuidv4();
    const newCode = generatePin();
    const newTitle = `${orig.title} (Salinan)`;

    await pool.query(
      'INSERT INTO quizizz_flashcards (id, dosen_id, code, title, subject, cards_json, is_public) VALUES (?, ?, ?, ?, ?, ?, ?)',
      [newId, String(req.user.id), newCode, newTitle, orig.subject, orig.cards_json, orig.is_public]
    );

    let cards = [];
    try { cards = typeof orig.cards_json === 'string' ? JSON.parse(orig.cards_json) : orig.cards_json; } catch (_) {}

    res.status(201).json({
      status: 'sukses',
      message: 'Set flashcard berhasil diduplikasi',
      flashcard: { id: newId, code: newCode, title: newTitle, subject: orig.subject, cards }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 18g. Simpan Progres Belajar Spaced Repetition Mahasiswa
router.post('/flashcards/:id/progress', async (req, res) => {
  try {
    const flashcardId = req.params.id;
    let { student_id, mastered_cards, review_needed_cards } = req.body;

    if (!student_id) {
      const authHeader = req.headers['authorization'];
      if (authHeader && authHeader.startsWith('Bearer ')) {
        try {
          const jwt = require('jsonwebtoken');
          const decoded = jwt.verify(authHeader.split(' ')[1], process.env.JWT_SECRET);
          student_id = decoded.id;
        } catch (e) {}
      }
    }
    student_id = String(student_id || 'anonim');

    const masteredJson = typeof mastered_cards === 'string' ? mastered_cards : JSON.stringify(mastered_cards || []);
    const reviewJson = typeof review_needed_cards === 'string' ? review_needed_cards : JSON.stringify(review_needed_cards || []);

    const [existing] = await pool.query(
      'SELECT id FROM quizizz_flashcard_progress WHERE flashcard_id = ? AND student_id = ?',
      [flashcardId, student_id]
    );

    if (existing.length > 0) {
      await pool.query(
        'UPDATE quizizz_flashcard_progress SET mastered_cards_json = ?, review_needed_cards_json = ? WHERE id = ?',
        [masteredJson, reviewJson, existing[0].id]
      );
    } else {
      const progressId = uuidv4();
      await pool.query(
        'INSERT INTO quizizz_flashcard_progress (id, flashcard_id, student_id, mastered_cards_json, review_needed_cards_json) VALUES (?, ?, ?, ?, ?)',
        [progressId, flashcardId, student_id, masteredJson, reviewJson]
      );
    }

    res.json({ status: 'sukses', message: 'Progres belajar disimpan' });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 18h. Ambil Progres Belajar Spaced Repetition Mahasiswa
router.get('/flashcards/:id/progress', async (req, res) => {
  try {
    const flashcardId = req.params.id;
    let studentId = req.query.student_id;

    if (!studentId) {
      const authHeader = req.headers['authorization'];
      if (authHeader && authHeader.startsWith('Bearer ')) {
        try {
          const jwt = require('jsonwebtoken');
          const decoded = jwt.verify(authHeader.split(' ')[1], process.env.JWT_SECRET);
          studentId = decoded.id;
        } catch (e) {}
      }
    }

    if (!studentId) return res.status(400).json({ status: 'gagal', message: 'student_id wajib diisi' });

    const [rows] = await pool.query(
      'SELECT * FROM quizizz_flashcard_progress WHERE flashcard_id = ? AND student_id = ?',
      [flashcardId, String(studentId)]
    );

    if (rows.length === 0) {
      return res.json({ status: 'sukses', progress: { mastered_cards: [], review_needed_cards: [] } });
    }

    const row = rows[0];
    res.json({
      status: 'sukses',
      progress: {
        mastered_cards: typeof row.mastered_cards_json === 'string' ? JSON.parse(row.mastered_cards_json || '[]') : row.mastered_cards_json,
        review_needed_cards: typeof row.review_needed_cards_json === 'string' ? JSON.parse(row.review_needed_cards_json || '[]') : row.review_needed_cards_json
      }
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============ 19. REKAP NILAI LIVE HOST & EXPORT CSV ============

// 19a. GET /api/quizizz/quizzes/:quizId/live-results
const handleGetLiveResults = async (req, res) => {
  try {
    const quizId = req.params.quizId || req.params.id;

    // FITUR "Riwayat Jawaban Gamified Quiz" (poin 2): sertakan sp.id (player_id)
    // untuk baris yang berasal dari sesi Kuis Gamifikasi Live, supaya bisa
    // ditelusuri detail jawaban per soalnya lewat tabel
    // quizizz_question_answers (yang sudah menyimpan jawaban & benar/salah
    // tiap soal per pemain, tapi sebelumnya tidak pernah ditampilkan).
    // Baris dari PR (homework_submissions / quizizz_homework_submissions)
    // tidak punya player_id (NULL) karena riwayat jawabannya sudah
    // tersedia lewat fitur "Lihat Riwayat Jawaban" yang sudah ada.
    const [rows] = await pool.query(
      `SELECT sp.id AS player_id, sp.display_name AS student_name, sp.score, gs.created_at AS completed_at,
              (SELECT COUNT(*) FROM quizizz_questions qq WHERE qq.quiz_id = gs.quiz_id OR qq.quiz_id = gs.id) AS total_questions
       FROM quizizz_session_players sp
       JOIN quizizz_game_sessions gs ON gs.id = sp.session_id
       WHERE gs.quiz_id = ? OR gs.id = ?
       UNION
       SELECT NULL AS player_id, hs.student_name, hs.score, hs.submitted_at AS completed_at, hs.total_questions
       FROM homework_submissions hs
       WHERE hs.homework_id = ? OR hs.homework_id IN (SELECT id FROM homework_assignments WHERE quiz_id = ?)
       UNION
       SELECT NULL AS player_id, qhs.student_name, qhs.score, qhs.submitted_at AS completed_at, qhs.total_questions
       FROM quizizz_homework_submissions qhs
       WHERE qhs.session_id = ? OR qhs.session_id IN (SELECT id FROM quizizz_sessions WHERE quiz_id = ?)
       ORDER BY score DESC, completed_at ASC`,
      [quizId, quizId, quizId, quizId, quizId, quizId]
    );

    const results = [];
    for (let index = 0; index < rows.length; index++) {
      const r = rows[index];
      let answers = [];
      if (r.player_id) {
        try {
          const [ansRows] = await pool.query(
            `SELECT qq.question_text, qq.correct_answer, qa.answer_text, qa.is_correct
             FROM quizizz_question_answers qa
             JOIN quizizz_questions qq ON qq.id = qa.question_id
             WHERE qa.player_id = ?
             ORDER BY qa.answered_at ASC`,
            [r.player_id]
          );
          answers = ansRows.map(a => ({
            question: a.question_text,
            student_answer: a.answer_text,
            correct_answer: a.correct_answer,
            is_correct: !!a.is_correct,
          }));
        } catch (_) {
          answers = [];
        }
      }
      results.push({
        rank: index + 1,
        student_name: r.student_name || 'Mahasiswa',
        score: parseInt(r.score || 0),
        total_questions: parseInt(r.total_questions || 0),
        completed_at: r.completed_at ? new Date(r.completed_at).toISOString() : new Date().toISOString(),
        answers,
      });
    }

    res.json({
      status: 'success',
      results: results,
      submissions: results
    });
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/quizzes/:quizId/live-results', handleGetLiveResults);
router.get('/sessions/:id/live-results', handleGetLiveResults);

// 19b. GET /api/quizizz/quizzes/:quizId/export-csv
const handleExportCsv = async (req, res) => {
  try {
    const quizId = req.params.quizId || req.params.id;

    const [rows] = await pool.query(
      `SELECT sp.display_name AS student_name, sp.score, gs.created_at AS completed_at,
              (SELECT COUNT(*) FROM quizizz_questions qq WHERE qq.quiz_id = gs.quiz_id OR qq.quiz_id = gs.id) AS total_questions
       FROM quizizz_session_players sp
       JOIN quizizz_game_sessions gs ON gs.id = sp.session_id
       WHERE gs.quiz_id = ? OR gs.id = ?
       UNION
       SELECT hs.student_name, hs.score, hs.submitted_at AS completed_at, hs.total_questions
       FROM homework_submissions hs
       WHERE hs.homework_id = ? OR hs.homework_id IN (SELECT id FROM homework_assignments WHERE quiz_id = ?)
       UNION
       SELECT qhs.student_name, qhs.score, qhs.submitted_at AS completed_at, qhs.total_questions
       FROM quizizz_homework_submissions qhs
       WHERE qhs.session_id = ? OR qhs.session_id IN (SELECT id FROM quizizz_sessions WHERE quiz_id = ?)
       ORDER BY score DESC, completed_at ASC`,
      [quizId, quizId, quizId, quizId, quizId, quizId]
    );

    const results = rows.map((r, index) => ({
      rank: index + 1,
      student_name: r.student_name || 'Mahasiswa',
      score: parseInt(r.score || 0),
      total_questions: parseInt(r.total_questions || 0),
      completed_at: r.completed_at ? new Date(r.completed_at).toISOString() : new Date().toISOString()
    }));

    const csvHeader = 'Peringkat,Nama Mahasiswa,Skor,Total Soal,Waktu Selesai\n';
    const csvRows = results.map(r =>
      `${r.rank},"${r.student_name.replace(/"/g, '""')}",${r.score},${r.total_questions},"${r.completed_at}"`
    ).join('\n');

    const csvContent = csvHeader + csvRows;

    res.setHeader('Content-Type', 'text/csv; charset=utf-8');
    res.setHeader('Content-Disposition', `attachment; filename="rekap_nilai_kuis_${quizId}.csv"`);
    res.status(200).send(csvContent);
  } catch (error) {
    console.error("CREATE QUIZ ERROR:", error); res.status(500).json({ status: 'gagal', message: error.message });
  }
};

router.get('/quizzes/:quizId/export-csv', handleExportCsv);
router.get('/sessions/:id/export-csv', handleExportCsv);

// ============================================================
// PRESENTASI INTERAKTIF (LESSON MODE) — LIVE, LINTAS DEVICE
// ============================================================

// Upload file .pptx dari komputer dosen -> mengekstrak SETIAP SLIDE ASLI
// (bukan sekadar mengumpulkan semua file gambar di dalam arsip .pptx).
// PENTING (perbaikan "PPT jangan dikompres, tampilkan isi asli"): versi
// SEBELUMNYA hanya mengambil semua file di folder ppt/media/ lalu
// menjadikan SETIAP GAMBAR sebagai satu slide -- ini SALAH, karena urutan
// nama file gambar (image1.png, image2.png, dst.) TIDAK SELALU sama dengan
// urutan slide sebenarnya, slide teks-tanpa-gambar jadi hilang total, dan
// slide dengan banyak gambar/tanpa gambar bikin jumlah "slide" hasil
// ekstraksi tidak cocok dengan jumlah slide asli di PowerPoint.
//
// Versi ini membaca STRUKTUR ASLI file .pptx (yang sebenarnya adalah arsip
// ZIP berisi XML):
//   1. ppt/presentation.xml -> urutan slide yang SEBENARNYA (bukan urutan
//      nama file), lewat daftar <p:sldId r:id="...">.
//   2. ppt/_rels/presentation.xml.rels -> memetakan r:id ke file slide XML.
//   3. Untuk tiap slide (sesuai urutan asli): ambil TEKS aslinya (semua
//      <a:t>...</a:t>) dan gambar yang benar-benar dipakai di slide itu
//      (lewat ppt/slides/_rels/slideN.xml.rels), TANPA proses kompres/
//      resize apapun -- byte gambar dipakai apa adanya (base64 langsung
//      dari arsip asli).
// Hasilnya: 1 slide hasil ekstraksi = 1 slide asli di PowerPoint, lengkap
// dengan teksnya, persis urutan aslinya.
function decodeXmlEntities(str) {
  return (str || '')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

function getXmlAttr(tagStr, attrName) {
  const m = tagStr.match(new RegExp(attrName + '="([^"]*)"'));
  return m ? m[1] : null;
}

router.post('/lessons/extract-pptx', verifyToken, pptxUpload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ status: 'gagal', message: 'File .pptx wajib diunggah' });
    }
    const zip = new AdmZip(req.file.buffer);

    const readEntryText = (entryName) => {
      const entry = zip.getEntry(entryName);
      return entry ? entry.getData().toString('utf8') : null;
    };

    const slidesOut = [];

    try {
      // 1) Urutan slide ASLI dari presentation.xml (bukan urutan nama file)
      const presentationXml = readEntryText('ppt/presentation.xml');
      const presRelsXml = readEntryText('ppt/_rels/presentation.xml.rels');
      if (!presentationXml || !presRelsXml) throw new Error('Struktur presentation.xml tidak ditemukan');

      const slideIdOrder = [...presentationXml.matchAll(/<p:sldId\b[^>]*>/g)]
        .map(m => getXmlAttr(m[0], 'r:id'))
        .filter(Boolean);

      const relMap = {}; // rId -> target path (relatif terhadap ppt/)
      for (const relMatch of presRelsXml.matchAll(/<Relationship\b[^>]*\/?>/g)) {
        const tag = relMatch[0];
        const id = getXmlAttr(tag, 'Id');
        const target = getXmlAttr(tag, 'Target');
        if (id && target) relMap[id] = target;
      }

      const orderedSlidePaths = slideIdOrder
        .map(rId => relMap[rId])
        .filter(Boolean)
        .map(target => (target.startsWith('/') ? target.slice(1) : `ppt/${target}`).replace('ppt/ppt/', 'ppt/'));

      if (orderedSlidePaths.length === 0) throw new Error('Tidak ada slide terdaftar di presentation.xml');

      for (let i = 0; i < orderedSlidePaths.length; i++) {
        const slidePath = orderedSlidePaths[i]; // contoh: ppt/slides/slide3.xml
        const slideXml = readEntryText(slidePath);
        if (!slideXml) continue;

        // Teks asli slide, MENGIKUTI STRUKTUR PARAGRAF ASLI (setiap
        // <a:p> = satu baris/poin list terpisah, persis seperti terlihat
        // di file PowerPoint aslinya). Sebelumnya semua run teks digabung
        // jadi satu paragraf panjang tanpa baris baru -- itu sebabnya
        // daftar bernomor terlihat berantakan dibanding aslinya.
        const paragraphs = [...slideXml.matchAll(/<a:p>[\s\S]*?<\/a:p>/g)]
          .map(pMatch => [...pMatch[0].matchAll(/<a:t>([^<]*)<\/a:t>/g)].map(m => decodeXmlEntities(m[1])).join(''))
          .filter(p => p.trim().length > 0);
        const fullText = paragraphs.join('\n');

        // Gambar yang BENAR-BENAR dipakai di slide ini (lewat file .rels
        // slide tsb), byte-nya diambil APA ADANYA dari arsip asli --
        // TIDAK ADA resize/kompresi/re-encode sama sekali di sini.
        const slideFileName = path.basename(slidePath); // slide3.xml
        const slideDir = path.dirname(slidePath); // ppt/slides
        const relsPath = `${slideDir}/_rels/${slideFileName}.rels`;
        const slideRelsXml = readEntryText(relsPath);

        let mediaUrl = null;
        if (slideRelsXml) {
          for (const relMatch of slideRelsXml.matchAll(/<Relationship\b[^>]*\/?>/g)) {
            const tag = relMatch[0];
            const type = getXmlAttr(tag, 'Type') || '';
            const target = getXmlAttr(tag, 'Target') || '';
            if (!type.toLowerCase().includes('image')) continue;
            // Target biasanya relatif: "../media/image7.png"
            const resolvedPath = path.posix.normalize(path.posix.join(slideDir, target));
            const ext = path.extname(resolvedPath).replace('.', '').toLowerCase();
            if (!/^(png|jpe?g|gif|bmp|emf|wmf)$/.test(ext)) continue; // lewati format non-raster (emf/wmf tetap boleh dicoba, browser modern kadang bisa)
            const mediaEntry = zip.getEntry(resolvedPath);
            if (!mediaEntry) continue;
            const mime = ext === 'jpg' ? 'jpeg' : ext;
            const base64 = mediaEntry.getData().toString('base64'); // byte asli, tanpa kompresi
            mediaUrl = `data:image/${mime};base64,${base64}`;
            break; // satu slide -> satu gambar utama (gambar pertama yang ditemukan)
          }
        }

        const firstLine = fullText.split('\n')[0] || '';
        const titleFromText = firstLine.length > 0 ? firstLine.slice(0, 60) : `Slide ${i + 1}`;
        slidesOut.push({
          title: titleFromText,
          type: mediaUrl ? 'image' : 'text',
          content: fullText,
          media_url: mediaUrl,
        });
      }
    } catch (structureErr) {
      // FALLBACK: kalau struktur pptx tidak terbaca (format tidak umum),
      // kembali ke cara lama (kumpulkan semua gambar) supaya tetap ada
      // hasil, daripada gagal total.
      console.error('extract-pptx: fallback ke mode lama karena', structureErr.message);
      const entries = zip.getEntries();
      const mediaEntries = entries
        .filter(e => e.entryName.startsWith('ppt/media/') && /\.(png|jpe?g|gif|bmp)$/i.test(e.entryName))
        .sort((a, b) => a.entryName.localeCompare(b.entryName, undefined, { numeric: true }));
      for (const entry of mediaEntries) {
        const ext = path.extname(entry.entryName).replace('.', '').toLowerCase();
        const mime = ext === 'jpg' ? 'jpeg' : ext;
        const base64 = entry.getData().toString('base64');
        slidesOut.push({ title: `Slide ${slidesOut.length + 1}`, type: 'image', content: '', media_url: `data:image/${mime};base64,${base64}` });
      }
    }

    if (slidesOut.length === 0) {
      return res.status(422).json({ status: 'gagal', message: 'Tidak ditemukan slide yang bisa diekstrak dari file PPT ini' });
    }

    // Dipertahankan juga sebagai 'images' (array media_url saja, boleh
    // berisi null untuk slide teks) supaya kompatibel dengan pemanggil lama
    // yang mengharap field 'images'.
    res.json({
      status: 'sukses',
      slides: slidesOut,
      images: slidesOut.map(s => s.media_url),
      count: slidesOut.length,
    });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: 'Gagal memproses file PPT: ' + error.message });
  }
});

// ----------------------------------------------------------------------
// Fitur "Upload PDF untuk Presentasi" (poin 3): mengekstrak TEKS dari
// setiap HALAMAN PDF, satu halaman = satu slide (mirip cara ekstraksi PPT,
// tapi hanya teks -- PDF tidak punya struktur gambar-per-slide seperti
// PPTX, dan merender halaman PDF jadi gambar butuh software konversi
// tambahan seperti poppler/pdftoppm yang TIDAK tersedia di server ini).
// PENTING: paket 'pdf-parse' WAJIB diinstal dulu di server (jalankan
// `npm install pdf-parse` di folder backend) sebelum fitur ini berfungsi.
// ----------------------------------------------------------------------
router.post('/lessons/extract-pdf', verifyToken, pptxUpload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).json({ status: 'gagal', message: 'File .pdf wajib diunggah' });
    }

    const fs = require('fs');
    const path = require('path');
    const os = require('os');
    const crypto = require('crypto');
    const { execSync } = require('child_process');

    const tempId = crypto.randomBytes(8).toString('hex');
    const tempDir = os.tmpdir();
    const pdfPath = path.join(tempDir, `upload_${tempId}.pdf`);
    const outPrefix = path.join(tempDir, `out_${tempId}`);

    // Tulis buffer PDF ke file sementara
    fs.writeFileSync(pdfPath, req.file.buffer);

    // Direktori penyimpanan gambar slide
    const uploadsLessonDir = path.join(__dirname, '../uploads/lessons');
    if (!fs.existsSync(uploadsLessonDir)) {
      fs.mkdirSync(uploadsLessonDir, { recursive: true });
    }

    // Resolusi optimal untuk presentasi web: 100 DPI
    let resolution = parseInt(req.body.resolution || '100', 10);
    if (isNaN(resolution) || resolution < 72) resolution = 72;
    if (resolution > 120) resolution = 110; // Cap resolusi agar render super cepat tanpa timeout

    // Cari binary konversi yang tersedia di server (pdftoppm atau gs)
    const findBinary = (candidates) => {
      for (const bin of candidates) {
        if (bin.includes('/') || bin.includes('\\')) {
          if (fs.existsSync(bin)) return bin;
        } else {
          try {
            const out = execSync(`which ${bin} 2>/dev/null`).toString().trim();
            if (out && fs.existsSync(out)) return out;
          } catch (_) {}
        }
      }
      return null;
    };

    const pdftoppmBin = findBinary(['/opt/homebrew/bin/pdftoppm', '/usr/local/bin/pdftoppm', '/usr/bin/pdftoppm', 'pdftoppm']);
    const gsBin = findBinary(['/usr/bin/gs', '/usr/local/bin/gs', '/opt/homebrew/bin/gs', 'gs']);

    let conversionSuccess = false;

    if (pdftoppmBin) {
      try {
        execSync(`"${pdftoppmBin}" -jpeg -r ${resolution} "${pdfPath}" "${outPrefix}"`);
        conversionSuccess = true;
      } catch (ppmErr) {
        console.warn('pdftoppm execution failed:', ppmErr.message);
      }
    }

    if (!conversionSuccess && gsBin) {
      try {
        execSync(`"${gsBin}" -dNOPAUSE -dBATCH -dSAFER -dQUIET -dNumRenderingThreads=4 -sDEVICE=jpeg -dJPEGQ=80 -r${resolution} -sOutputFile="${outPrefix}-%04d.jpg" "${pdfPath}"`);
        conversionSuccess = true;
      } catch (gsErr) {
        console.warn('Ghostscript execution failed:', gsErr.message);
      }
    }

    let slidesOut = [];

    if (conversionSuccess) {
      // Baca file gambar hasil konversi
      const files = fs.readdirSync(tempDir)
        .filter(f => f.startsWith(`out_${tempId}`) && f.endsWith('.jpg'))
        .sort((a, b) => {
          const numA = parseInt(a.match(/[-_](\d+)\.jpg$/i)?.[1] || '0', 10);
          const numB = parseInt(b.match(/[-_](\d+)\.jpg$/i)?.[1] || '0', 10);
          return numA - numB;
        });

      for (let i = 0; i < files.length; i++) {
        const file = files[i];
        const tempFilePath = path.join(tempDir, file);
        const destFileName = `pdf_${tempId}_${String(i + 1).padStart(3, '0')}.jpg`;
        const destFilePath = path.join(uploadsLessonDir, destFileName);

        // Pindahkan/salin file gambar ke folder uploads/lessons
        fs.copyFileSync(tempFilePath, destFilePath);
        try { fs.unlinkSync(tempFilePath); } catch (_) {}

        const mediaUrl = `/uploads/lessons/${destFileName}`;

        slidesOut.push({
          title: `Halaman PDF ${i + 1}`,
          type: 'image',
          content: '',
          media_url: mediaUrl,
        });
      }
    } else {
      // Fallback: ekstrak teks menggunakan pdf-parse jika tidak ada binary konversi gambar
      try {
        const pdfParse = require('pdf-parse');
        const parsed = await pdfParse(req.file.buffer);
        const text = parsed.text || '';
        const pages = text.split(/\f|\n\s*\n\s*\n/).filter(p => p.trim().length > 0);
        for (let i = 0; i < pages.length; i++) {
          const pageText = pages[i].trim();
          const firstLine = pageText.split('\n')[0] || `Halaman PDF ${i + 1}`;
          slidesOut.push({
            title: firstLine.slice(0, 60),
            type: 'text',
            content: pageText,
            media_url: null,
          });
        }
      } catch (parseErr) {
        console.error('pdf-parse fallback failed:', parseErr.message);
      }
    }

    // Bersihkan file PDF sementara
    try { fs.unlinkSync(pdfPath); } catch (_) {}

    if (slidesOut.length === 0) {
      return res.status(422).json({ status: 'gagal', message: 'Tidak dapat mengekstrak halaman dari file PDF ini.' });
    }

    res.json({
      status: 'sukses',
      slides: slidesOut,
      images: slidesOut.map(s => s.media_url),
      count: slidesOut.length,
    });
  } catch (error) {
    res.status(500).json({ status: 'gagal', message: 'Gagal memproses file PDF: ' + error.message });
  }
});

// ============================================================================
// FITUR "REKAP NILAI (GRADEBOOK)" & "PRESENSI QR CODE PEKANAN"
// ============================================================================

// ----------------------------------------------------------------------------
// A. GRADEBOOK (REKAP NILAI)
// ----------------------------------------------------------------------------

// 1. Ambil seluruh data Rekap Nilai untuk suatu kelas
router.get('/classes/:classId/gradebook', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;

    // Ambil info kelas
    const [classes] = await pool.query('SELECT * FROM quizizz_classes WHERE id = ?', [classId]);
    if (classes.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Kelas tidak ditemukan' });
    }
    const classInfo = classes[0];

    // Ambil daftar anggota kelas beserta data profil (NIM, Nama)
    const [students] = await pool.query(
      `SELECT m.student_id, COALESCE(u.full_name, m.student_name) AS full_name,
              u.nim, u.email, u.avatar_url, m.joined_at
       FROM quizizz_class_members m
       LEFT JOIN users u ON u.id = m.student_id
       WHERE m.class_id = ?
       ORDER BY CASE WHEN u.nim IS NULL OR u.nim = '' THEN 1 ELSE 0 END, u.nim ASC, full_name ASC`,
      [classId]
    );

    // Ambil daftar assessment / kolom penilaian yang terdaftar di kelas
    let [assessments] = await pool.query(
      'SELECT * FROM class_assessments WHERE class_id = ? ORDER BY order_index ASC, created_at ASC',
      [classId]
    );

    // Ambil seluruh nilai mahasiswa di kelas ini
    const [gradesRows] = await pool.query(
      'SELECT * FROM class_student_grades WHERE class_id = ?',
      [classId]
    );

    // Bentuk grade matrix: { [student_id]: { [assessment_id]: { score, notes } } }
    const grades = {};
    for (const g of gradesRows) {
      if (!grades[g.student_id]) grades[g.student_id] = {};
      grades[g.student_id][g.assessment_id] = {
        id: g.id,
        score: g.score !== null ? Number(g.score) : null,
        notes: g.notes || null,
        updated_at: g.updated_at,
      };
    }

    res.json({
      status: 'sukses',
      class: classInfo,
      students: students.map((s, idx) => ({
        no: idx + 1,
        student_id: s.student_id,
        nim: s.nim || '-',
        name: s.full_name,
        email: s.email,
        avatar_url: s.avatar_url,
      })),
      assessments: assessments.map(a => ({
        id: a.id,
        title: a.title,
        type: a.type,
        max_score: a.max_score,
        order_index: a.order_index,
        created_at: a.created_at,
      })),
      grades,
    });
  } catch (error) {
    console.error('GRADEBOOK GET ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 2. Tambah kolom penilaian baru (Assessment)
router.post('/classes/:classId/gradebook/items', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const { title, type, max_score } = req.body;
    if (!title || !title.trim()) {
      return res.status(400).json({ status: 'gagal', message: 'Judul penilaian wajib diisi' });
    }

    const id = uuidv4();
    const [maxOrder] = await pool.query('SELECT COALESCE(MAX(order_index), 0) + 1 AS next_order FROM class_assessments WHERE class_id = ?', [classId]);
    const nextOrder = maxOrder[0]?.next_order || 1;

    await pool.query(
      'INSERT INTO class_assessments (id, class_id, title, type, max_score, order_index) VALUES (?, ?, ?, ?, ?, ?)',
      [id, classId, title.trim(), type || 'quiz', max_score || 100, nextOrder]
    );

    res.status(201).json({
      status: 'sukses',
      message: 'Kolom penilaian berhasil ditambahkan',
      item: { id, class_id: classId, title: title.trim(), type: type || 'quiz', max_score: max_score || 100, order_index: nextOrder }
    });
  } catch (error) {
    console.error('GRADEBOOK ITEM CREATE ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 3. Simpan / Update Nilai Mahasiswa
router.put('/classes/:classId/gradebook/grades', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const { assessment_id, student_id, score, notes } = req.body;

    if (!assessment_id || !student_id) {
      return res.status(400).json({ status: 'gagal', message: 'assessment_id dan student_id wajib diisi' });
    }

    // Ambil NIM mahasiswa
    const [userRows] = await pool.query('SELECT nim FROM users WHERE id = ?', [student_id]);
    const nim = userRows[0]?.nim || '-';

    const [existing] = await pool.query(
      'SELECT id FROM class_student_grades WHERE assessment_id = ? AND student_id = ?',
      [assessment_id, student_id]
    );

    const scoreVal = (score !== undefined && score !== null && score !== '') ? Number(score) : null;
    const notesVal = notes !== undefined ? (notes ? String(notes).trim() : null) : null;

    if (existing.length > 0) {
      await pool.query(
        'UPDATE class_student_grades SET score = ?, notes = ?, nim = ? WHERE id = ?',
        [scoreVal, notesVal, nim, existing[0].id]
      );
    } else {
      await pool.query(
        'INSERT INTO class_student_grades (id, class_id, assessment_id, student_id, nim, score, notes) VALUES (?, ?, ?, ?, ?, ?, ?)',
        [uuidv4(), classId, assessment_id, student_id, nim, scoreVal, notesVal]
      );
    }

    res.json({ status: 'sukses', message: 'Nilai berhasil disimpan' });
  } catch (error) {
    console.error('GRADEBOOK GRADE UPDATE ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 4. Hapus kolom penilaian
router.delete('/classes/:classId/gradebook/items/:itemId', verifyToken, async (req, res) => {
  try {
    const { classId, itemId } = req.params;
    await pool.query('DELETE FROM class_student_grades WHERE assessment_id = ? AND class_id = ?', [itemId, classId]);
    await pool.query('DELETE FROM class_assessments WHERE id = ? AND class_id = ?', [itemId, classId]);
    res.json({ status: 'sukses', message: 'Kolom penilaian berhasil dihapus' });
  } catch (error) {
    console.error('GRADEBOOK ITEM DELETE ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ----------------------------------------------------------------------------
// B. PRESENSI & ABSENSI QR CODE (PEKAN KE-SEKIAN)
// ----------------------------------------------------------------------------

// Helper generate kode presensi unik mis. STG-W01-8392
function generateAttendanceCode(weekNumber) {
  const chars = '23456789ABCDEFGHJKLMNPQRSTUVWXYZ';
  let rand = '';
  for (let i = 0; i < 4; i++) rand += chars[Math.floor(Math.random() * chars.length)];
  const wStr = String(weekNumber || 1).padStart(2, '0');
  return `W${wStr}-${rand}`;
}

// 1. Dosen: Ambil seluruh sesi presensi di kelas
router.get('/classes/:classId/attendance-sessions', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const [sessions] = await pool.query(
      `SELECT s.*,
              (SELECT COUNT(*) FROM class_attendance_records r WHERE r.session_id = s.id AND r.status = 'hadir') AS total_hadir,
              (SELECT COUNT(*) FROM quizizz_class_members m WHERE m.class_id = s.class_id) AS total_members
       FROM class_attendance_sessions s
       WHERE s.class_id = ?
       ORDER BY s.week_number DESC, s.opened_at DESC`,
      [classId]
    );
    res.json({ status: 'sukses', sessions });
  } catch (error) {
    console.error('ATTENDANCE SESSIONS GET ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 2. Dosen: Buka sesi presensi pekan ke-sekian (tampilkan QR Code)
router.post('/classes/:classId/attendance-sessions', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'dosen') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya dosen yang dapat membuka sesi presensi' });
    }

    const { classId } = req.params;
    const weekNumber = Number(req.body.week_number) || 1;
    const title = req.body.title ? req.body.title.trim() : `Presensi Pekan ${weekNumber}`;

    // Cek apakah sudah ada sesi open untuk pekan ini
    const [existingOpen] = await pool.query(
      "SELECT * FROM class_attendance_sessions WHERE class_id = ? AND week_number = ? AND status = 'open'",
      [classId, weekNumber]
    );

    if (existingOpen.length > 0) {
      const sess = existingOpen[0];
      return res.json({
        status: 'sukses',
        message: 'Sesi presensi pekan ini sedang aktif',
        session: sess,
      });
    }

    const id = uuidv4();
    const sessionCode = generateAttendanceCode(weekNumber);
    const qrData = JSON.stringify({
      app: 'classly',
      type: 'attendance',
      session_id: id,
      session_code: sessionCode,
      class_id: classId,
      week: weekNumber,
    });

    await pool.query(
      'INSERT INTO class_attendance_sessions (id, class_id, dosen_id, week_number, title, session_code, qr_data, status) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [id, classId, String(req.user.id), weekNumber, title, sessionCode, qrData, 'open']
    );

    const [created] = await pool.query('SELECT * FROM class_attendance_sessions WHERE id = ?', [id]);
    res.status(201).json({
      status: 'sukses',
      message: `Presensi Pekan ${weekNumber} berhasil dibuka!`,
      session: created[0],
    });
  } catch (error) {
    console.error('ATTENDANCE OPEN SESSION ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 3. Detail Sesi Presensi beserta data live kehadiran mahasiswa (auto-sync keikutsertaan kuis)
router.get('/attendance-sessions/:sessionId', verifyToken, async (req, res) => {
  try {
    const { sessionId } = req.params;

    const [sessions] = await pool.query(
      `SELECT s.*, c.class_name, c.subject
       FROM class_attendance_sessions s
       JOIN quizizz_classes c ON c.id = s.class_id
       WHERE s.id = ?`,
      [sessionId]
    );
    if (sessions.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Sesi presensi tidak ditemukan' });
    }
    const session = sessions[0];
    const week = session.week_number;

    // Ambil daftar seluruh mahasiswa kelas beserta status presensinya di sesi ini
    const [attendeesRows] = await pool.query(
      `SELECT m.student_id, COALESCE(u.full_name, m.student_name) AS student_name,
              u.nim, u.email, u.avatar_url,
              r.id AS record_id,
              r.status AS record_status,
              r.attended_at, r.notes AS record_notes,
              g.score AS quiz_score, g.notes AS quiz_notes, g.updated_at AS quiz_date
       FROM quizizz_class_members m
       JOIN class_attendance_sessions s ON s.class_id = m.class_id
       LEFT JOIN users u ON u.id = m.student_id
       LEFT JOIN class_attendance_records r ON r.session_id = s.id AND r.student_id = m.student_id
       LEFT JOIN class_assessments a ON a.class_id = s.class_id AND (a.order_index = s.week_number OR a.title LIKE CONCAT('%Pekan ', s.week_number, '%') OR a.title LIKE CONCAT('%Kuis ', s.week_number, '%'))
       LEFT JOIN class_student_grades g ON g.assessment_id = a.id AND g.student_id = m.student_id
       WHERE s.id = ?
       ORDER BY CASE WHEN u.nim IS NULL OR u.nim = '' THEN 1 ELSE 0 END, u.nim ASC, student_name ASC`,
      [sessionId]
    );

    const attendees = attendeesRows.map((a, idx) => {
      let finalStatus = a.record_status || 'belum_hadir';
      let finalNotes = a.record_notes || a.quiz_notes || null;
      let attendedAt = a.attended_at;

      if (a.record_status === 'hadir') {
        finalStatus = 'hadir';
      } else if (a.quiz_score !== null && Number(a.quiz_score) >= 0) {
        finalStatus = 'hadir';
        if (!finalNotes) finalNotes = `Hadir via Kuis Pekan ${week}`;
        if (!attendedAt) attendedAt = a.quiz_date;
      } else if (finalNotes && finalNotes.toLowerCase().includes('sakit')) {
        finalStatus = 'sakit';
      } else if (finalNotes && finalNotes.toLowerCase().includes('izin')) {
        finalStatus = 'izin';
      }

      return {
        no: idx + 1,
        student_id: a.student_id,
        nim: a.nim || '-',
        student_name: a.student_name,
        email: a.email,
        avatar_url: a.avatar_url,
        record_id: a.record_id,
        status: finalStatus,
        attended_at: attendedAt,
        notes: finalNotes,
      };
    });

    const totalHadir = attendees.filter(a => a.status === 'hadir').length;

    res.json({
      status: 'sukses',
      session,
      total_hadir: totalHadir,
      total_members: attendees.length,
      attendees,
    });
  } catch (error) {
    console.error('ATTENDANCE DETAIL ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 4. Dosen: Tutup Sesi Presensi
router.put('/attendance-sessions/:sessionId/close', verifyToken, async (req, res) => {
  try {
    const { sessionId } = req.params;
    await pool.query("UPDATE class_attendance_sessions SET status = 'closed', closed_at = NOW() WHERE id = ?", [sessionId]);
    res.json({ status: 'sukses', message: 'Sesi presensi telah ditutup' });
  } catch (error) {
    console.error('ATTENDANCE CLOSE ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 5. Mahasiswa: Scan QR Code / Submit Kode Presensi
router.post('/attendance/submit', verifyToken, async (req, res) => {
  try {
    let rawInput = (req.body.session_code || req.body.code || req.body.qr_data || '').toString().trim();
    let sessionId = req.body.session_id;

    if (!rawInput && !sessionId) {
      return res.status(400).json({ status: 'gagal', message: 'Kode atau QR Presensi wajib diisi' });
    }

    // Ekstrak jika format JSON dari QR code
    if (rawInput.startsWith('{') && rawInput.endsWith('}')) {
      try {
        const parsed = JSON.parse(rawInput);
        if (parsed.session_code) rawInput = parsed.session_code;
        if (parsed.session_id) sessionId = parsed.session_id;
      } catch (_) {}
    }

    // Cari sesi presensi yang sedang OPEN
    let query = "SELECT s.*, c.class_name, c.subject FROM class_attendance_sessions s JOIN quizizz_classes c ON c.id = s.class_id WHERE s.status = 'open' AND ";
    let params = [];
    if (sessionId) {
      query += 's.id = ?';
      params.push(sessionId);
    } else {
      query += '(s.session_code = ? OR s.session_code = ?)';
      params.push(rawInput.toUpperCase(), rawInput);
    }

    const [sessions] = await pool.query(query, params);
    if (sessions.length === 0) {
      return res.status(404).json({
        status: 'gagal',
        message: 'Kode presensi tidak ditemukan atau sesi presensi sudah ditutup oleh dosen.',
      });
    }

    const session = sessions[0];
    const studentId = String(req.user.id);

    // Ambil data mahasiswa
    const [userRows] = await pool.query('SELECT full_name, nim FROM users WHERE id = ?', [studentId]);
    const studentName = userRows[0]?.full_name || req.user.name || 'Mahasiswa';
    const studentNim = userRows[0]?.nim || '-';

    // Pastikan mahasiswa terdaftar sebagai anggota kelas (auto-join jika belum)
    const [memberRows] = await pool.query(
      'SELECT id FROM quizizz_class_members WHERE class_id = ? AND student_id = ?',
      [session.class_id, studentId]
    );
    if (memberRows.length === 0) {
      await pool.query(
        'INSERT INTO quizizz_class_members (id, class_id, student_id, student_name) VALUES (?, ?, ?, ?)',
        [uuidv4(), session.class_id, studentId, studentName]
      );
    }

    // Cek apakah sudah pernah presensi
    const [existingRecord] = await pool.query(
      'SELECT * FROM class_attendance_records WHERE session_id = ? AND student_id = ?',
      [session.id, studentId]
    );

    let attendedAt = new Date();
    if (existingRecord.length > 0) {
      if (existingRecord[0].status === 'hadir') {
        return res.json({
          status: 'sukses',
          already_attended: true,
          message: `Anda SUDAH tercatat HADIR pada ${session.title}!`,
          session: {
            id: session.id,
            title: session.title,
            week_number: session.week_number,
            class_name: session.class_name,
            attended_at: existingRecord[0].attended_at,
          },
        });
      } else {
        await pool.query(
          "UPDATE class_attendance_records SET status = 'hadir', attended_at = NOW(), nim = ?, student_name = ? WHERE id = ?",
          [studentNim, studentName, existingRecord[0].id]
        );
      }
    } else {
      const recordId = uuidv4();
      await pool.query(
        "INSERT INTO class_attendance_records (id, session_id, class_id, student_id, nim, student_name, status, attended_at) VALUES (?, ?, ?, ?, ?, ?, 'hadir', NOW())",
        [recordId, session.id, session.class_id, studentId, studentNim, studentName]
      );
    }

    // Realtime broadcast via Socket.IO
    try {
      const io = req.app.get('io');
      if (io) {
        io.to(session.id).emit('attendance_updated', {
          session_id: session.id,
          student_id: studentId,
          nim: studentNim,
          student_name: studentName,
          status: 'hadir',
          attended_at: attendedAt,
        });
        io.to(`session_${session.id}`).emit('attendance_updated', {
          session_id: session.id,
          student_id: studentId,
          nim: studentNim,
          student_name: studentName,
          status: 'hadir',
          attended_at: attendedAt,
        });
      }
    } catch (_) {}

    res.json({
      status: 'sukses',
      message: `Presensi Berhasil! Anda tercatat HADIR pada ${session.title}.`,
      session: {
        id: session.id,
        title: session.title,
        week_number: session.week_number,
        class_name: session.class_name,
        attended_at: attendedAt,
      },
    });
  } catch (error) {
    console.error('ATTENDANCE SUBMIT ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 6. Dosen: Ubah status presensi mahasiswa secara manual (Hadir, Sakit, Izin, Alfa)
router.put('/attendance-records/:recordId/status', verifyToken, async (req, res) => {
  try {
    const { recordId } = req.params;
    const { status, notes } = req.body;
    await pool.query(
      'UPDATE class_attendance_records SET status = ?, notes = ? WHERE id = ?',
      [status || 'hadir', notes || null, recordId]
    );
    res.json({ status: 'sukses', message: 'Status presensi diperbarui' });
  } catch (error) {
    console.error('ATTENDANCE RECORD STATUS UPDATE ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 7. Mahasiswa: Riwayat presensi milik sendiri (termasuk auto-sync keikutsertaan kuis)
router.get('/attendance/student-history', verifyToken, async (req, res) => {
  try {
    const studentId = String(req.user.id);

    // Ambil seluruh sesi presensi dari kelas-kelas yang diikuti mahasiswa
    const [sessions] = await pool.query(
      `SELECT s.id AS session_id, s.week_number, s.title AS session_title, s.opened_at, s.status AS session_status,
              c.id AS class_id, c.class_name, c.subject,
              r.id AS record_id, r.status AS record_status, r.attended_at, r.notes AS record_notes
       FROM class_attendance_sessions s
       JOIN quizizz_classes c ON c.id = s.class_id
       JOIN quizizz_class_members m ON m.class_id = c.id AND m.student_id = ?
       LEFT JOIN class_attendance_records r ON r.session_id = s.id AND r.student_id = ?
       ORDER BY s.week_number DESC, s.opened_at DESC`,
      [studentId, studentId]
    );

    // Ambil juga seluruh kuis / grades mahasiswa untuk auto-sinkronisasi keikutsertaan kuis
    const [grades] = await pool.query(
      `SELECT g.assessment_id, g.score, g.notes AS quiz_notes, g.updated_at,
              a.class_id, a.title AS assessment_title, a.order_index
       FROM class_student_grades g
       JOIN class_assessments a ON a.id = g.assessment_id
       WHERE g.student_id = ?`,
      [studentId]
    );

    const history = sessions.map(sess => {
      const recStatus = sess.record_status;
      const recNotes = sess.record_notes;
      const week = sess.week_number;

      // Cari kuis terkait pekan ini
      const matchingGrade = grades.find(g => 
        g.class_id === sess.class_id && 
        (g.order_index === week || (g.assessment_title && g.assessment_title.toLowerCase().includes(`pekan ${week}`)))
      );

      let finalStatus = 'belum_hadir';
      let source = 'Belum Ada Data';
      let notes = recNotes || null;
      let attendedAt = sess.attended_at || null;

      if (recStatus === 'hadir') {
        finalStatus = 'hadir';
        source = 'Scan QR Code / Dosen';
      } else if (matchingGrade && matchingGrade.score !== null && Number(matchingGrade.score) >= 0) {
        // Otomatis hadir jika berpartisipasi pada kuis pekan ini!
        finalStatus = 'hadir';
        source = `Keikutsertaan ${matchingGrade.assessment_title || ('Kuis Pekan ' + week)}`;
        attendedAt = matchingGrade.updated_at || sess.opened_at;
        if (!notes) {
          notes = matchingGrade.quiz_notes || 'Tercatat otomatis dari keikutsertaan kuis';
        }
      } else if (recStatus === 'sakit' || (matchingGrade?.quiz_notes && matchingGrade.quiz_notes.toLowerCase().includes('sakit'))) {
        finalStatus = 'sakit';
        source = 'Keterangan Sakit';
        notes = recNotes || matchingGrade?.quiz_notes || 'Sakit';
      } else if (recStatus === 'izin' || (matchingGrade?.quiz_notes && matchingGrade.quiz_notes.toLowerCase().includes('izin'))) {
        finalStatus = 'izin';
        source = 'Keterangan Izin';
        notes = recNotes || matchingGrade?.quiz_notes || 'Izin';
      } else if (matchingGrade?.quiz_notes) {
        notes = matchingGrade.quiz_notes;
      }

      return {
        session_id: sess.session_id,
        week_number: sess.week_number,
        session_title: sess.session_title,
        class_id: sess.class_id,
        class_name: sess.class_name,
        subject: sess.subject,
        record_id: sess.record_id,
        status: finalStatus,
        source: source,
        attended_at: attendedAt,
        notes: notes,
      };
    });

    res.json({ status: 'sukses', history });
  } catch (error) {
    console.error('ATTENDANCE STUDENT HISTORY ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 8. Mahasiswa: Ambil seluruh rekap nilai diri sendiri
router.get('/student/my-grades', verifyToken, async (req, res) => {
  try {
    const studentId = String(req.user.id);
    let classId = req.query.classId || req.query.class_id;

    if (!classId) {
      const [memberships] = await pool.query(
        'SELECT class_id FROM quizizz_class_members WHERE student_id = ? ORDER BY joined_at DESC LIMIT 1',
        [studentId]
      );
      if (memberships.length > 0) {
        classId = memberships[0].class_id;
      }
    }

    if (!classId) {
      return res.json({
        status: 'sukses',
        class: null,
        items: [],
        stats: { total_assessments: 0, completed_assessments: 0, average_score: 0 }
      });
    }

    // Ambil info kelas
    const [classes] = await pool.query('SELECT * FROM quizizz_classes WHERE id = ?', [classId]);
    const classInfo = classes[0] || null;

    // Ambil semua assessments
    const [assessments] = await pool.query(
      'SELECT * FROM class_assessments WHERE class_id = ? ORDER BY order_index ASC, created_at ASC',
      [classId]
    );

    // Ambil nilai mahasiswa
    const [gradesRows] = await pool.query(
      'SELECT * FROM class_student_grades WHERE class_id = ? AND student_id = ?',
      [classId, studentId]
    );

    const gradesMap = {};
    for (const g of gradesRows) {
      gradesMap[g.assessment_id] = g;
    }

    let completedCount = 0;
    let scoreSum = 0;

    const items = assessments.map((a, idx) => {
      const g = gradesMap[a.id];
      const hasScore = g && g.score !== null;
      const numScore = hasScore ? Number(g.score) : null;
      if (hasScore) {
        completedCount++;
        scoreSum += numScore;
      }
      return {
        no: idx + 1,
        assessment_id: a.id,
        title: a.title,
        type: a.type || 'quiz',
        max_score: Number(a.max_score) || 100,
        score: numScore,
        notes: g?.notes || null,
        status: hasScore ? 'tuntas' : 'belum',
        updated_at: g?.updated_at || a.created_at,
      };
    });

    const avg = completedCount > 0 ? Number((scoreSum / completedCount).toFixed(1)) : 0;

    res.json({
      status: 'sukses',
      class: classInfo,
      items,
      stats: {
        total_assessments: assessments.length,
        completed_assessments: completedCount,
        average_score: avg,
      }
    });
  } catch (error) {
    console.error('STUDENT MY-GRADES ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

router.get('/classes/:classId/my-grades', verifyToken, async (req, res) => {
  try {
    const studentId = String(req.user.id);
    const { classId } = req.params;

    const [classes] = await pool.query('SELECT * FROM quizizz_classes WHERE id = ?', [classId]);
    const classInfo = classes[0] || null;

    const [assessments] = await pool.query(
      'SELECT * FROM class_assessments WHERE class_id = ? ORDER BY order_index ASC, created_at ASC',
      [classId]
    );

    const [gradesRows] = await pool.query(
      'SELECT * FROM class_student_grades WHERE class_id = ? AND student_id = ?',
      [classId, studentId]
    );

    const gradesMap = {};
    for (const g of gradesRows) {
      gradesMap[g.assessment_id] = g;
    }

    let completedCount = 0;
    let scoreSum = 0;

    const items = assessments.map((a, idx) => {
      const g = gradesMap[a.id];
      const hasScore = g && g.score !== null;
      const numScore = hasScore ? Number(g.score) : null;
      if (hasScore) {
        completedCount++;
        scoreSum += numScore;
      }
      return {
        no: idx + 1,
        assessment_id: a.id,
        title: a.title,
        type: a.type || 'quiz',
        max_score: Number(a.max_score) || 100,
        score: numScore,
        notes: g?.notes || null,
        status: hasScore ? 'tuntas' : 'belum',
        updated_at: g?.updated_at || a.created_at,
      };
    });

    const avg = completedCount > 0 ? Number((scoreSum / completedCount).toFixed(1)) : 0;

    res.json({
      status: 'sukses',
      class: classInfo,
      items,
      stats: {
        total_assessments: assessments.length,
        completed_assessments: completedCount,
        average_score: avg,
      }
    });
  } catch (error) {
    console.error('STUDENT MY-GRADES ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============================================================================
// FITUR "KELAS RISET / CAPSTONE"
// ============================================================================

// 1. GET Semua Grup Riset dalam Satu Kelas (lengkap dengan anggota & unread chat)
router.get('/classes/:classId/research-groups', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const userId = String(req.user.id);

    // Ambil daftar grup
    const [groups] = await pool.query(
      `SELECT rg.*,
              (SELECT COUNT(*) FROM research_group_members rgm WHERE rgm.group_id = rg.id) AS member_count,
              (SELECT c.dosen_id FROM quizizz_classes c WHERE c.id = rg.class_id) AS dosen_id,
              (SELECT u.full_name FROM quizizz_classes c JOIN users u ON u.id = c.dosen_id WHERE c.id = rg.class_id) AS default_dosen_name
       FROM research_groups rg
       WHERE rg.class_id = ?
       ORDER BY rg.group_number ASC, rg.created_at ASC`,
      [classId]
    );

    // Ambil seluruh anggota per grup
    const [members] = await pool.query(
      `SELECT rgm.*, u.full_name, u.avatar_url, u.email, COALESCE(rgm.nim, u.nim) AS nim
       FROM research_group_members rgm
       LEFT JOIN users u ON u.id = rgm.student_id
       WHERE rgm.class_id = ?
       ORDER BY rgm.joined_at ASC`,
      [classId]
    );

    const membersByGroup = {};
    for (const m of members) {
      if (!membersByGroup[m.group_id]) membersByGroup[m.group_id] = [];
      membersByGroup[m.group_id].push({
        id: m.id,
        group_id: m.group_id,
        student_id: m.student_id,
        student_name: m.full_name || m.student_name,
        nim: m.nim || '-',
        email: m.email,
        avatar_url: m.avatar_url,
        joined_at: m.joined_at,
      });
    }

    // Ambil riwayat unread messages per grup untuk user ini
    const [reads] = await pool.query(
      'SELECT group_id, last_read_at FROM research_discussion_reads WHERE user_id = ?',
      [userId]
    );
    const readMap = {};
    for (const r of reads) {
      readMap[r.group_id] = r.last_read_at;
    }

    const [unreads] = await pool.query(
      `SELECT rd.group_id, COUNT(*) AS unread_count
       FROM research_discussions rd
       JOIN research_groups rg ON rg.id = rd.group_id
       LEFT JOIN research_discussion_reads rdr ON rdr.group_id = rd.group_id AND rdr.user_id = ?
       WHERE rg.class_id = ? 
         AND rd.sender_id != ?
         AND (rd.recipient_id IS NULL OR rd.recipient_id = ? OR ? = (SELECT dosen_id FROM quizizz_classes WHERE id = rg.class_id))
         AND rd.created_at > COALESCE(rdr.last_read_at, '1970-01-01')
       GROUP BY rd.group_id`,
      [userId, classId, userId, userId, userId]
    );
    // Hitung unread count untuk forum kelas dan PM
    const [forumUnreadRows] = await pool.query(
      `SELECT COUNT(*) AS cnt
       FROM research_discussions rd
       LEFT JOIN research_discussion_reads rdr ON rdr.group_id = ? AND rdr.user_id = ?
       WHERE rd.class_id = ?
         AND (rd.group_id = ? OR rd.group_id = 'CLASS_GENERAL')
         AND rd.recipient_id IS NULL
         AND rd.sender_id != ?
         AND rd.created_at > COALESCE(rdr.last_read_at, '1970-01-01')`,
      [`CLASS_${classId}`, userId, classId, `CLASS_${classId}`, userId]
    );
    const classForumUnread = forumUnreadRows[0]?.cnt || 0;

    const [pmUnreadRows] = await pool.query(
      `SELECT COUNT(*) AS cnt
       FROM research_discussions rd
       LEFT JOIN research_discussion_reads rdr ON rdr.group_id = CONCAT('PM_${classId}_', rd.sender_id) AND rdr.user_id = ?
       WHERE rd.class_id = ?
         AND rd.recipient_id = ?
         AND rd.sender_id != ?
         AND rd.created_at > COALESCE(rdr.last_read_at, '1970-01-01')`,
      [userId, classId, userId, userId]
    );
    const totalPmUnread = pmUnreadRows[0]?.cnt || 0;

    const unreadMap = {};
    for (const u of unreads) {
      unreadMap[u.group_id] = u.unread_count;
    }

    let result = groups.map(g => ({
      id: g.id,
      class_id: g.class_id,
      dosen_id: g.dosen_id,
      dosen_pembimbing_1: g.dosen_pembimbing_1 || g.dosen_pembimbing || g.default_dosen_name || 'Dr. GELAR BUDIMAN S.T., M.T.',
      dosen_pembimbing_2: g.dosen_pembimbing_2 || '',
      dosen_pembimbing: g.dosen_pembimbing_1 || g.dosen_pembimbing || g.default_dosen_name || 'Dr. GELAR BUDIMAN S.T., M.T.',
      group_number: g.group_number,
      group_name: g.group_name,
      title: g.title,
      dosen_kelas: g.dosen_kelas || '',
      group_code: g.group_code,
      qr_data: g.qr_data,
      created_at: g.created_at,
      updated_at: g.updated_at,
      members: membersByGroup[g.id] || [],
      member_count: (membersByGroup[g.id] || []).length,
      unread_count: unreadMap[g.id] || 0,
      is_my_group: (membersByGroup[g.id] || []).some(m => m.student_id === userId) || g.dosen_id === userId,
    }));

    if (req.user.role === 'mahasiswa') {
      result = result.filter(g => g.is_my_group);
    }

    res.json({
      status: 'sukses',
      groups: result,
      class_chat_summary: {
        class_forum_unread: classForumUnread,
        total_pm_unread: totalPmUnread,
        total_unread: classForumUnread + totalPmUnread,
      },
    });
  } catch (error) {
    console.error('GET RESEARCH GROUPS ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 2. POST Buat Grup Capstone Baru (Auto-increment nomor grup & generate QR Code)
router.post('/classes/:classId/research-groups', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'dosen') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya dosen yang dapat membuat grup riset' });
    }
    const { classId } = req.params;
    const { title, dosen_pembimbing_1, dosen_pembimbing_2, dosen_kelas } = req.body;
    if (!title || !title.trim()) {
      return res.status(400).json({ status: 'gagal', message: 'Judul Tugas Akhir / Riset wajib diisi' });
    }

    // Auto increment nomor grup
    const [maxRows] = await pool.query(
      'SELECT COALESCE(MAX(group_number), 0) AS max_num FROM research_groups WHERE class_id = ?',
      [classId]
    );
    const groupNumber = (maxRows[0]?.max_num || 0) + 1;
    const groupName = `Grup ${groupNumber}`;

    const id = uuidv4();
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    let rand = '';
    for (let i = 0; i < 4; i++) rand += chars[Math.floor(Math.random() * chars.length)];
    const groupCode = `R-G${groupNumber}-${rand}`;

    const dosenPembimbing1Val = (dosen_pembimbing_1 && dosen_pembimbing_1.trim()) ? dosen_pembimbing_1.trim() : (req.user.full_name || 'Dr. GELAR BUDIMAN S.T., M.T.');
    const dosenPembimbing2Val = (dosen_pembimbing_2 && dosen_pembimbing_2.trim()) ? dosen_pembimbing_2.trim() : '';
    const dosenKelasVal = (dosen_kelas && dosen_kelas.trim()) ? dosen_kelas.trim() : '';

    const qrPayload = JSON.stringify({
      app: 'classly',
      type: 'research_group',
      group_id: id,
      group_code: groupCode,
      class_id: classId,
      group_number: groupNumber,
      title: title.trim(),
      dosen_pembimbing_1: dosenPembimbing1Val,
      dosen_pembimbing_2: dosenPembimbing2Val,
      dosen_kelas: dosenKelasVal,
    });

    await pool.query(
      `INSERT INTO research_groups (id, class_id, dosen_id, group_number, group_name, title, dosen_pembimbing_1, dosen_pembimbing_2, dosen_kelas, group_code, qr_data)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [id, classId, String(req.user.id), groupNumber, groupName, title.trim(), dosenPembimbing1Val, dosenPembimbing2Val, dosenKelasVal, groupCode, qrPayload]
    );

    const createdGroup = {
      id,
      class_id: classId,
      dosen_id: String(req.user.id),
      dosen_pembimbing_1: dosenPembimbing1Val,
      dosen_pembimbing_2: dosenPembimbing2Val,
      dosen_pembimbing: dosenPembimbing1Val,
      group_number: groupNumber,
      group_name: groupName,
      title: title.trim(),
      dosen_kelas: dosenKelasVal,
      group_code: groupCode,
      qr_data: qrPayload,
      members: [],
      member_count: 0,
      unread_count: 0,
    };

    res.status(201).json({
      status: 'sukses',
      message: 'Grup Capstone berhasil dibuat',
      group: createdGroup,
    });
  } catch (error) {
    console.error('CREATE RESEARCH GROUP ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 3. PUT Edit Judul / Dosen Pembimbing / Dosen Kelas / Nama Grup Riset (Dosen & Mahasiswa anggota grup)
router.put('/research-groups/:groupId', verifyToken, async (req, res) => {
  try {
    const { groupId } = req.params;
    const { title, group_name, dosen_pembimbing_1, dosen_pembimbing_2, dosen_kelas } = req.body;

    if (req.user.role === 'dosen') {
      // Dosen diizinkan mengedit semua grup di kelasnya
    } else if (req.user.role === 'mahasiswa') {
      // Mahasiswa hanya dapat mengedit jika merupakan anggota dari grup ini
      const [members] = await pool.query(
        'SELECT 1 FROM research_group_members WHERE group_id = ? AND student_id = ?',
        [groupId, String(req.user.id)]
      );
      if (members.length === 0) {
        return res.status(403).json({ status: 'gagal', message: 'Hanya anggota grup yang dapat mengubah data grup' });
      }
    } else {
      return res.status(403).json({ status: 'gagal', message: 'Akses ditolak' });
    }

    const updates = [];
    const values = [];
    if (title !== undefined && title.trim()) { updates.push('title = ?'); values.push(title.trim()); }
    if (dosen_pembimbing_1 !== undefined) { updates.push('dosen_pembimbing_1 = ?'); values.push(dosen_pembimbing_1.trim()); }
    if (dosen_pembimbing_2 !== undefined) { updates.push('dosen_pembimbing_2 = ?'); values.push(dosen_pembimbing_2.trim()); }
    if (dosen_kelas !== undefined) { updates.push('dosen_kelas = ?'); values.push(dosen_kelas.trim()); }
    if (group_name !== undefined && req.user.role === 'dosen' && group_name.trim()) { updates.push('group_name = ?'); values.push(group_name.trim()); }

    if (updates.length === 0) {
      return res.status(400).json({ status: 'gagal', message: 'Tidak ada perubahan data' });
    }
    values.push(groupId);

    await pool.query(`UPDATE research_groups SET ${updates.join(', ')} WHERE id = ?`, values);

    // Update QR Payload if needed
    try {
      const [grpRows] = await pool.query('SELECT * FROM research_groups WHERE id = ?', [groupId]);
      if (grpRows.length > 0) {
        const grp = grpRows[0];
        const qrPayload = JSON.stringify({
          app: 'classly',
          type: 'research_group',
          group_id: grp.id,
          group_code: grp.group_code,
          class_id: grp.class_id,
          group_number: grp.group_number,
          title: grp.title,
          dosen_pembimbing_1: grp.dosen_pembimbing_1 || 'Dr. GELAR BUDIMAN S.T., M.T.',
          dosen_pembimbing_2: grp.dosen_pembimbing_2 || '',
          dosen_kelas: grp.dosen_kelas || '',
        });
        await pool.query('UPDATE research_groups SET qr_data = ? WHERE id = ?', [qrPayload, groupId]);
      }
    } catch (_) {}

    res.json({ status: 'sukses', message: 'Grup berhasil diperbarui' });
  } catch (error) {
    console.error('UPDATE RESEARCH GROUP ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 4. DELETE Hapus Grup Riset
router.delete('/research-groups/:groupId', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'dosen') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya dosen yang dapat menghapus grup' });
    }
    const { groupId } = req.params;

    await pool.query('DELETE FROM research_discussion_reads WHERE group_id = ?', [groupId]);
    await pool.query('DELETE FROM research_discussions WHERE group_id = ?', [groupId]);
    await pool.query('DELETE FROM research_documents WHERE group_id = ?', [groupId]);
    await pool.query('DELETE FROM research_group_members WHERE group_id = ?', [groupId]);
    await pool.query('DELETE FROM research_groups WHERE id = ?', [groupId]);

    res.json({ status: 'sukses', message: 'Grup berhasil dihapus' });
  } catch (error) {
    console.error('DELETE RESEARCH GROUP ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 4b. DELETE Hapus/Keluarkan Mahasiswa dari Grup Riset (Dosen)
router.delete('/research-groups/:groupId/members/:studentId', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'dosen') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya dosen yang dapat mengeluarkan mahasiswa dari grup' });
    }
    const { groupId, studentId } = req.params;

    await pool.query(
      'DELETE FROM research_group_members WHERE group_id = ? AND (student_id = ? OR id = ?)',
      [groupId, studentId, studentId]
    );

    res.json({ status: 'sukses', message: 'Mahasiswa berhasil dikeluarkan dari grup' });
  } catch (error) {
    console.error('DELETE RESEARCH GROUP MEMBER ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 5. GET Riwayat Diskusi Grup & Japri
router.get('/research-groups/:groupId/discussions', verifyToken, async (req, res) => {
  try {
    const { groupId } = req.params;
    const userId = String(req.user.id);

    // Ambil info grup & kelas
    const [groups] = await pool.query(
      `SELECT rg.*, c.dosen_id FROM research_groups rg JOIN quizizz_classes c ON c.id = rg.class_id WHERE rg.id = ?`,
      [groupId]
    );
    if (groups.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Grup tidak ditemukan' });
    }
    const grp = groups[0];

    // Ambil pesan: broadcast grup (recipient_id IS NULL) ATAU japri milik user ini (atau dosen melihat semua japri dalam grupnya)
    const [discussions] = await pool.query(
      `SELECT rd.id, rd.group_id, rd.class_id, rd.sender_id,
              COALESCE(u.full_name, rd.sender_name) AS sender_name,
              COALESCE(u.role, rd.sender_role) AS sender_role,
              rd.recipient_id, rd.message, rd.attachment_url, rd.created_at,
              u.avatar_url, u.full_name AS sender_full_name,
              ru.full_name AS recipient_full_name
       FROM research_discussions rd
       LEFT JOIN users u ON u.id = rd.sender_id
       LEFT JOIN users ru ON ru.id = rd.recipient_id
       WHERE rd.group_id = ?
         AND (rd.recipient_id IS NULL OR rd.sender_id = ? OR rd.recipient_id = ? OR ? = ?)
       ORDER BY rd.created_at ASC`,
      [groupId, userId, userId, userId, grp.dosen_id]
    );

    // Tandai sudah dibaca untuk user ini
    const readId = uuidv4();
    await pool.query(
      `INSERT INTO research_discussion_reads (id, group_id, user_id, last_read_at)
       VALUES (?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE last_read_at = NOW()`,
      [readId, groupId, userId]
    );

    res.json({ status: 'sukses', group: grp, discussions });
  } catch (error) {
    console.error('GET DISCUSSIONS ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 6. POST Kirim Pesan Diskusi (Grup atau Japri)
router.post('/research-groups/:groupId/discussions', verifyToken, async (req, res) => {
  try {
    const { groupId } = req.params;
    const { message, recipient_id, attachment_url } = req.body;
    if (!message || !message.trim()) {
      return res.status(400).json({ status: 'gagal', message: 'Pesan tidak boleh kosong' });
    }

    const [groups] = await pool.query('SELECT * FROM research_groups WHERE id = ?', [groupId]);
    if (groups.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Grup tidak ditemukan' });
    }
    const grp = groups[0];

    const id = uuidv4();
    const senderId = String(req.user.id);
    const [senderRows] = await pool.query('SELECT full_name, role FROM users WHERE id = ?', [senderId]);
    const senderName = (senderRows.length > 0 && senderRows[0].full_name) ? senderRows[0].full_name : (req.user.name || req.user.full_name || 'User');
    const senderRole = (senderRows.length > 0 && senderRows[0].role) ? senderRows[0].role : (req.user.role || 'mahasiswa');
    const cleanRecipientId = recipient_id ? String(recipient_id) : null;

    await pool.query(
      `INSERT INTO research_discussions (id, group_id, class_id, sender_id, sender_name, sender_role, recipient_id, message, attachment_url)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [id, groupId, grp.class_id, senderId, senderName, senderRole, cleanRecipientId, message.trim(), attachment_url || null]
    );

    // Ambil baris yang baru dimasukkan
    const [inserted] = await pool.query(
      `SELECT rd.id, rd.group_id, rd.class_id, rd.sender_id,
              COALESCE(u.full_name, rd.sender_name) AS sender_name,
              COALESCE(u.role, rd.sender_role) AS sender_role,
              rd.recipient_id, rd.message, rd.attachment_url, rd.created_at,
              u.avatar_url, u.full_name AS sender_full_name, ru.full_name AS recipient_full_name
       FROM research_discussions rd
       LEFT JOIN users u ON u.id = rd.sender_id
       LEFT JOIN users ru ON ru.id = rd.recipient_id
       WHERE rd.id = ?`,
      [id]
    );
    const newMsg = inserted[0];

    // Tandai langsung sudah dibaca untuk pengirim
    const readId = uuidv4();
    await pool.query(
      `INSERT INTO research_discussion_reads (id, group_id, user_id, last_read_at)
       VALUES (?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE last_read_at = NOW()`,
      [readId, groupId, senderId]
    );

    // Emit event socket.io untuk real-time update
    try {
      const io = req.app.get('io');
      if (io) {
        io.emit('research_chat_message', newMsg);
        io.to(`group_${groupId}`).emit('research_chat_message', newMsg);
        io.to(`session_${grp.class_id}`).emit('research_chat_notification', {
          group_id: groupId,
          class_id: grp.class_id,
          sender_name: senderName,
          message: message.trim(),
        });
      }
    } catch (_) {}

    res.status(201).json({ status: 'sukses', message: newMsg });
  } catch (error) {
    console.error('SEND DISCUSSION ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 7. POST Tandai Diskusi Dibaca
router.post('/research-groups/:groupId/discussions/read', verifyToken, async (req, res) => {
  try {
    const { groupId } = req.params;
    const userId = String(req.user.id);
    const readId = uuidv4();

    await pool.query(
      `INSERT INTO research_discussion_reads (id, group_id, user_id, last_read_at)
       VALUES (?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE last_read_at = NOW()`,
      [readId, groupId, userId]
    );
    res.json({ status: 'sukses', message: 'Telah ditandai dibaca' });
  } catch (error) {
    console.error('READ DISCUSSION ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// ============================================================================
// FITUR DISKUSI SELURUH KELAS & PRIVATE MESSAGING (JAPRI ALA WHATSAPP)
// ============================================================================

// A. GET /classes/:classId/class-discussions
// Mengambil riwayat pesan forum kelas (jika peer_id kosong) ATAU pesan PM 1-on-1 dengan peer_id
router.get('/classes/:classId/class-discussions', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const { peer_id } = req.query;
    const userId = String(req.user.id);

    let query = '';
    let params = [];
    let readGroupId = '';

    if (peer_id && peer_id !== 'general') {
      // 1-on-1 Private Message antara req.user.id dan peer_id dalam kelas ini
      const peerId = String(peer_id);
      readGroupId = `PM_${classId}_${peerId}`;
      query = `
        SELECT rd.id, rd.group_id, rd.class_id, rd.sender_id,
               COALESCE(u.full_name, rd.sender_name) AS sender_name,
               COALESCE(u.role, rd.sender_role) AS sender_role,
               rd.recipient_id, rd.message, rd.attachment_url, rd.created_at,
               u.avatar_url, u.full_name AS sender_full_name, ru.full_name AS recipient_full_name
        FROM research_discussions rd
        LEFT JOIN users u ON u.id = rd.sender_id
        LEFT JOIN users ru ON ru.id = rd.recipient_id
        WHERE rd.class_id = ?
          AND ((rd.sender_id = ? AND rd.recipient_id = ?) OR (rd.sender_id = ? AND rd.recipient_id = ?))
        ORDER BY rd.created_at ASC
      `;
      params = [classId, userId, peerId, peerId, userId];
    } else {
      // Forum Diskusi Seluruh Kelas (Broadcast ke semua anggota kelas)
      readGroupId = `CLASS_${classId}`;
      query = `
        SELECT rd.id, rd.group_id, rd.class_id, rd.sender_id,
               COALESCE(u.full_name, rd.sender_name) AS sender_name,
               COALESCE(u.role, rd.sender_role) AS sender_role,
               rd.recipient_id, rd.message, rd.attachment_url, rd.created_at,
               u.avatar_url, u.full_name AS sender_full_name
        FROM research_discussions rd
        LEFT JOIN users u ON u.id = rd.sender_id
        WHERE rd.class_id = ?
          AND (rd.group_id = ? OR rd.group_id = 'CLASS_GENERAL')
          AND rd.recipient_id IS NULL
        ORDER BY rd.created_at ASC
      `;
      params = [classId, `CLASS_${classId}`];
    }

    const [discussions] = await pool.query(query, params);

    // Auto mark as read saat dibuka
    const readId = uuidv4();
    await pool.query(
      `INSERT INTO research_discussion_reads (id, group_id, user_id, last_read_at)
       VALUES (?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE last_read_at = NOW()`,
      [readId, readGroupId, userId]
    );

    res.json({ status: 'sukses', discussions });
  } catch (error) {
    console.error('GET CLASS DISCUSSIONS ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// B. POST /classes/:classId/class-discussions
// Mengirim pesan ke forum kelas (jika recipient_id kosong) ATAU japri ke user tertentu
router.post('/classes/:classId/class-discussions', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const { message, recipient_id, attachment_url } = req.body;
    if (!message || !message.trim()) {
      return res.status(400).json({ status: 'gagal', message: 'Pesan tidak boleh kosong' });
    }

    const id = uuidv4();
    const senderId = String(req.user.id);
    const [senderRows] = await pool.query('SELECT full_name, role FROM users WHERE id = ?', [senderId]);
    const senderName = (senderRows.length > 0 && senderRows[0].full_name) ? senderRows[0].full_name : (req.user.name || req.user.full_name || 'User');
    const senderRole = (senderRows.length > 0 && senderRows[0].role) ? senderRows[0].role : (req.user.role || 'mahasiswa');
    const cleanRecipientId = recipient_id && String(recipient_id).trim() !== '' && String(recipient_id) !== 'general'
      ? String(recipient_id).trim()
      : null;

    const groupId = cleanRecipientId ? `PM_${classId}` : `CLASS_${classId}`;

    await pool.query(
      `INSERT INTO research_discussions (id, group_id, class_id, sender_id, sender_name, sender_role, recipient_id, message, attachment_url)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [id, groupId, classId, senderId, senderName, senderRole, cleanRecipientId, message.trim(), attachment_url || null]
    );

    const [inserted] = await pool.query(
      `SELECT rd.id, rd.group_id, rd.class_id, rd.sender_id,
              COALESCE(u.full_name, rd.sender_name) AS sender_name,
              COALESCE(u.role, rd.sender_role) AS sender_role,
              rd.recipient_id, rd.message, rd.attachment_url, rd.created_at,
              u.avatar_url, u.full_name AS sender_full_name, ru.full_name AS recipient_full_name
       FROM research_discussions rd
       LEFT JOIN users u ON u.id = rd.sender_id
       LEFT JOIN users ru ON ru.id = rd.recipient_id
       WHERE rd.id = ?`,
      [id]
    );
    const newMsg = inserted[0];

    // Tandai langsung sudah dibaca untuk pengirim
    const readId = uuidv4();
    const readKey = cleanRecipientId ? `PM_${classId}_${cleanRecipientId}` : `CLASS_${classId}`;
    await pool.query(
      `INSERT INTO research_discussion_reads (id, group_id, user_id, last_read_at)
       VALUES (?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE last_read_at = NOW()`,
      [readId, readKey, senderId]
    );

    // Socket.IO real-time emission
    try {
      const io = req.app.get('io');
      if (io) {
        io.emit('class_chat_message', newMsg);
        io.to(`session_${classId}`).emit('class_chat_message', newMsg);
        io.to(`class_${classId}`).emit('class_chat_message', newMsg);
        io.to(`session_${classId}`).emit('class_chat_notification', {
          class_id: classId,
          sender_id: senderId,
          sender_name: senderName,
          recipient_id: cleanRecipientId,
          message: message.trim(),
          is_pm: !!cleanRecipientId,
        });
      }
    } catch (_) {}

    res.status(201).json({ status: 'sukses', message: newMsg });
  } catch (error) {
    console.error('POST CLASS DISCUSSION ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// C. GET /classes/:classId/chat-contacts
// Mengambil kontak chat (Dosen + Seluruh Mahasiswa sekelas) dan unread badge masing-masing
router.get('/classes/:classId/chat-contacts', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const userId = String(req.user.id);

    // 1. Ambil Dosen
    const [dosenRows] = await pool.query(
      `SELECT u.id, u.full_name, u.email, u.avatar_url, 'dosen' AS role, NULL AS nim
       FROM quizizz_classes c
       JOIN users u ON u.id = c.dosen_id
       WHERE c.id = ?`,
      [classId]
    );
    const dosen = dosenRows[0] || null;

    // 2. Ambil seluruh mahasiswa di kelas ini beserta nama grupnya jika sudah punya grup
    const [students] = await pool.query(
      `SELECT DISTINCT u.id, u.full_name, u.email, u.avatar_url, u.nim, 'mahasiswa' AS role,
              rg.group_name, rg.title AS group_title
       FROM quizizz_class_members cm
       JOIN users u ON u.id = cm.student_id
       LEFT JOIN research_group_members rgm ON rgm.student_id = u.id
       LEFT JOIN research_groups rg ON rg.id = rgm.group_id AND rg.class_id = cm.class_id
       WHERE cm.class_id = ?
       ORDER BY u.full_name ASC`,
      [classId]
    );

    // 3. Hitung unread count untuk forum kelas umum
    const [forumUnread] = await pool.query(
      `SELECT COUNT(*) AS cnt
       FROM research_discussions rd
       LEFT JOIN research_discussion_reads rdr ON rdr.group_id = ? AND rdr.user_id = ?
       WHERE rd.class_id = ?
         AND (rd.group_id = ? OR rd.group_id = 'CLASS_GENERAL')
         AND rd.recipient_id IS NULL
         AND rd.sender_id != ?
         AND rd.created_at > COALESCE(rdr.last_read_at, '1970-01-01')`,
      [`CLASS_${classId}`, userId, classId, `CLASS_${classId}`, userId]
    );
    const classForumUnread = forumUnread[0]?.cnt || 0;

    // 4. Hitung unread count untuk masing-masing kontak (PM)
    const [pmUnreads] = await pool.query(
      `SELECT rd.sender_id, COUNT(*) AS unread_count
       FROM research_discussions rd
       LEFT JOIN research_discussion_reads rdr ON rdr.group_id = CONCAT('PM_${classId}_', rd.sender_id) AND rdr.user_id = ?
       WHERE rd.class_id = ?
         AND rd.recipient_id = ?
         AND rd.sender_id != ?
         AND rd.created_at > COALESCE(rdr.last_read_at, '1970-01-01')
       GROUP BY rd.sender_id`,
      [userId, classId, userId, userId]
    );
    const pmUnreadMap = {};
    for (const u of pmUnreads) {
      pmUnreadMap[u.sender_id] = u.unread_count;
    }

    // Pasangkan unread ke dosen & mahasiswa
    if (dosen) {
      dosen.unread_count = pmUnreadMap[dosen.id] || 0;
    }

    const studentList = students.map(s => ({
      ...s,
      unread_count: pmUnreadMap[s.id] || 0,
      is_current_user: s.id === userId,
    }));

    res.json({
      status: 'sukses',
      dosen,
      students: studentList,
      class_forum_unread: classForumUnread,
    });
  } catch (error) {
    console.error('GET CHAT CONTACTS ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// D. POST /classes/:classId/class-discussions/read
router.post('/classes/:classId/class-discussions/read', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const { peer_id } = req.body;
    const userId = String(req.user.id);
    const readId = uuidv4();
    const readGroupId = peer_id && peer_id !== 'general' ? `PM_${classId}_${peer_id}` : `CLASS_${classId}`;

    await pool.query(
      `INSERT INTO research_discussion_reads (id, group_id, user_id, last_read_at)
       VALUES (?, ?, ?, NOW())
       ON DUPLICATE KEY UPDATE last_read_at = NOW()`,
      [readId, readGroupId, userId]
    );
    res.json({ status: 'sukses', message: 'Telah ditandai dibaca' });
  } catch (error) {
    console.error('READ CLASS DISCUSSION ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// E. GET /classes/:classId/research-students-activity
// Mengambil daftar seluruh mahasiswa yang join kelas riset capstone beserta data grup, judul riset, dan akumulasi poin keaktifan
router.get('/classes/:classId/research-students-activity', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;

    // 1. Ambil seluruh mahasiswa yang terdaftar di kelas riset ini beserta grup dan judul risetnya
    const [students] = await pool.query(
      `SELECT cm.id AS member_id, cm.joined_at, u.id AS student_id, u.full_name, u.nim, u.email, u.avatar_url,
              rg.id AS group_id, rg.group_name, rg.group_number, rg.title AS group_title
       FROM quizizz_class_members cm
       JOIN users u ON u.id = cm.student_id
       LEFT JOIN research_group_members rgm ON rgm.student_id = u.id AND rgm.class_id = cm.class_id
       LEFT JOIN research_groups rg ON rg.id = rgm.group_id AND rg.class_id = cm.class_id
       WHERE cm.class_id = ?
       ORDER BY u.full_name ASC`,
      [classId]
    );

    // 2. Ambil seluruh pesan diskusi di kelas ini (baik di grup riset, forum kelas, maupun PM)
    const [messages] = await pool.query(
      `SELECT rd.sender_id, rd.message, rd.group_id, rd.recipient_id, rd.created_at
       FROM research_discussions rd
       WHERE rd.class_id = ? OR rd.group_id IN (SELECT id FROM research_groups WHERE class_id = ?)`,
      [classId, classId]
    );

    // 3. Ambil seluruh dokumen approval yang diunggah di kelas ini
    const [documents] = await pool.query(
      `SELECT rd.student_id, rd.id AS doc_id, rd.document_name, rd.status, rd.created_at
       FROM research_documents rd
       WHERE rd.class_id = ?`,
      [classId]
    );

    // Helper: Hitung jumlah kata dalam satu kalimat/teks
    function countWords(str) {
      if (!str || typeof str !== 'string') return 0;
      const words = str.trim().split(/\s+/).filter(w => /[a-zA-Z0-9]/.test(w));
      return words.length;
    }

    // Helper: Hitung jumlah kalimat valid (hanya kalimat dengan MINIMAL 4 KATA yang mendapat poin)
    function countValidSentences(text) {
      if (!text || typeof text !== 'string') return 0;
      const clean = text.trim();
      if (!clean) return 0;

      // Pisahkan berdasarkan tanda akhir kalimat (. ? ! ;) atau baris baru (\n)
      const parts = clean.split(/[.?!;\n]+/).map(s => s.trim()).filter(s => /[a-zA-Z0-9]/.test(s));
      
      let validCount = 0;
      for (const part of parts) {
        if (countWords(part) >= 4) {
          validCount += 1;
        }
      }

      // Jika teks utuh tanpa tanda pemisah kalimat (1 kalimat tunggal dengan minimal 4 kata)
      if (parts.length === 0 && countWords(clean) >= 4) {
        validCount = 1;
      }

      return validCount;
    }

    // Inisialisasi peta keaktifan per student_id
    const activityMap = {};
    for (const s of students) {
      activityMap[s.student_id] = {
        forum_chat_count: 0,
        forum_chat_sentences: 0,
        forum_chat_points: 0,
        group_chat_count: 0,
        group_chat_sentences: 0,
        group_chat_points: 0,
        doc_count: 0,
        doc_points: 0,
        total_points: 0,
      };
    }

    // Akumulasikan poin dari pesan chat:
    // 1. Kalimat harus minimal 4 kata
    // 2. Japri TIDAK mendapatkan poin (hanya grup besar / forum kelas & grup kecil / grup riset)
    // 3. Poin di grup besar 2x lipat (2 poin per kalimat valid vs 1 poin di grup kecil)
    for (const msg of messages) {
      const senderId = String(msg.sender_id);
      if (!activityMap[senderId]) continue;

      const isPM = !!msg.recipient_id || (msg.group_id && String(msg.group_id).startsWith('PM_'));
      if (isPM) {
        // Aturan 2: Japri tidak mendapatkan poin
        continue;
      }

      const isClassForum = (msg.group_id === `CLASS_${classId}` || msg.group_id === 'CLASS_GENERAL');
      const validSentences = countValidSentences(msg.message);
      if (validSentences <= 0) continue;

      if (isClassForum) {
        // Aturan 3: Grup Besar (Forum Kelas) = 2 poin per kalimat valid
        const pts = validSentences * 2;
        activityMap[senderId].forum_chat_count += 1;
        activityMap[senderId].forum_chat_sentences += validSentences;
        activityMap[senderId].forum_chat_points += pts;
        activityMap[senderId].total_points += pts;
      } else {
        // Aturan 3: Grup Kecil (Grup Riset/TA) = 1 poin per kalimat valid
        const pts = validSentences * 1;
        activityMap[senderId].group_chat_count += 1;
        activityMap[senderId].group_chat_sentences += validSentences;
        activityMap[senderId].group_chat_points += pts;
        activityMap[senderId].total_points += pts;
      }
    }

    // Akumulasikan poin dari unggahan dokumen approval (1 poin per dokumen)
    for (const doc of documents) {
      const studentId = String(doc.student_id);
      if (activityMap[studentId]) {
        activityMap[studentId].doc_count += 1;
        activityMap[studentId].doc_points += 1;
        activityMap[studentId].total_points += 1;
      }
    }

    const result = students.map((s, index) => {
      const act = activityMap[s.student_id] || {
        forum_chat_count: 0,
        forum_chat_sentences: 0,
        forum_chat_points: 0,
        group_chat_count: 0,
        group_chat_sentences: 0,
        group_chat_points: 0,
        doc_count: 0,
        doc_points: 0,
        total_points: 0,
      };

      return {
        index: index + 1,
        member_id: s.member_id,
        student_id: s.student_id,
        is_current_user: s.student_id === String(req.user.id),
        nama: s.full_name || 'Mahasiswa',
        nim: s.nim || '-',
        email: s.email || '-',
        avatar_url: s.avatar_url || null,
        group_id: s.group_id || null,
        group_name: s.group_name || (s.group_number ? `Grup ${s.group_number}` : '-'),
        group_title: s.group_title || '-',
        keaktifan: act.total_points,
        detail_keaktifan: {
          forum_chat_count: act.forum_chat_count,
          forum_chat_sentences: act.forum_chat_sentences,
          forum_chat_points: act.forum_chat_points,
          group_chat_count: act.group_chat_count,
          group_chat_sentences: act.group_chat_sentences,
          group_chat_points: act.group_chat_points,
          chat_points: act.forum_chat_points + act.group_chat_points,
          doc_count: act.doc_count,
          doc_points: act.doc_points,
          total_points: act.total_points,
        },
      };
    });

    res.json({
      status: 'sukses',
      total_students: result.length,
      students: result,
    });
  } catch (error) {
    console.error('GET RESEARCH STUDENTS ACTIVITY ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 8. GET Daftar Dokumen Approval dalam Kelas Riset
router.get('/classes/:classId/research-documents', verifyToken, async (req, res) => {
  try {
    const { classId } = req.params;
    const userId = String(req.user.id);
    const isDosen = req.user.role === 'dosen';

    let query = `
      SELECT rd.*, 
             COALESCE(NULLIF(u.full_name, ''), NULLIF(rd.student_name, ''), 'Mahasiswa') AS student_name,
             COALESCE(NULLIF(u.nim, ''), '-') AS student_nim,
             u.full_name AS student_full_name,
             u.avatar_url AS student_avatar, u.email AS student_email,
             rg.group_name, rg.group_number, rg.title AS group_title,
             c.dosen_id, du.full_name AS dosen_name, du.signature_url AS dosen_signature_url
      FROM research_documents rd
      LEFT JOIN research_groups rg ON rg.id = rd.group_id
      JOIN quizizz_classes c ON c.id = rd.class_id
      LEFT JOIN users u ON u.id = rd.student_id
      LEFT JOIN users du ON du.id = c.dosen_id
      WHERE rd.class_id = ?
    `;
    const params = [classId];

    // Jika mahasiswa, filter dokumen milik grupnya atau yang dia submit
    if (!isDosen) {
      query += ` AND (rd.student_id = ? OR rd.group_id IN (SELECT group_id FROM research_group_members WHERE student_id = ?))`;
      params.push(userId, userId);
    }

    query += ` ORDER BY rd.created_at DESC`;

    const [documents] = await pool.query(query, params);

    // Ambil info status TTD dosen kelas
    const [dosenRows] = await pool.query(
      `SELECT u.id, u.full_name, u.signature_url FROM quizizz_classes c JOIN users u ON u.id = c.dosen_id WHERE c.id = ?`,
      [classId]
    );
    const dosenInfo = dosenRows[0] || null;

    res.json({
      status: 'sukses',
      documents,
      dosen_signature_ready: !!dosenInfo?.signature_url,
      dosen_info: dosenInfo,
    });
  } catch (error) {
    console.error('GET RESEARCH DOCUMENTS ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

const optionalUploadDoc = (req, res, next) => {
  uploadDoc.single('file')(req, res, (err) => {
    next();
  });
};

// 9. POST Unggah Dokumen untuk Approval (Mahasiswa)
router.post('/classes/:classId/research-documents', verifyToken, optionalUploadDoc, async (req, res) => {
  try {
    if (req.user.role === 'dosen') {
      return res.status(403).json({
        status: 'gagal',
        message: 'Dosen tidak dapat menambahkan dokumen approval. Pengajuan dokumen hanya dapat dilakukan oleh mahasiswa.',
      });
    }

    const { classId } = req.params;
    const { group_id, document_name, deadline, doc_type } = req.body;

    let filename;
    if (req.file) {
      filename = req.file.filename;
    } else if (req.body && (req.body.file_base64 || req.body.document_base64)) {
      const rawBase64 = req.body.file_base64 || req.body.document_base64;
      const matches = rawBase64.match(/^data:([A-Za-z-+\/]+);base64,(.+)$/);
      let buffer;
      let ext = '.pdf';
      if (req.body.filename && path.extname(req.body.filename)) {
        ext = path.extname(req.body.filename).toLowerCase();
      }
      if (matches && matches.length === 3) {
        buffer = Buffer.from(matches[2], 'base64');
      } else {
        buffer = Buffer.from(rawBase64, 'base64');
      }
      filename = `doc-${Date.now()}-${uuidv4()}${ext}`;
      fs.writeFileSync(path.join(docDir, filename), buffer);
    } else {
      return res.status(400).json({ status: 'gagal', message: 'File dokumen (PDF/DOC) wajib diunggah' });
    }

    if (!document_name || !document_name.trim()) {
      return res.status(400).json({ status: 'gagal', message: 'Nama dokumen wajib diisi' });
    }
    if (!deadline) {
      return res.status(400).json({ status: 'gagal', message: 'Deadline approval dokumen wajib diisi' });
    }

    // Cari group_id jika tidak dikirim dari form (ambil dari membership mahasiswa di kelas ini)
    let targetGroupId = group_id;
    if (!targetGroupId) {
      const [mRows] = await pool.query(
        'SELECT group_id FROM research_group_members WHERE class_id = ? AND student_id = ?',
        [classId, String(req.user.id)]
      );
      if (mRows.length > 0) targetGroupId = mRows[0].group_id;
    }
    if (!targetGroupId) {
      const [gRows] = await pool.query(
        'SELECT rg.id FROM research_groups rg JOIN research_group_members rgm ON rgm.group_id = rg.id WHERE rg.class_id = ? AND rgm.student_id = ?',
        [classId, String(req.user.id)]
      );
      if (gRows.length > 0) targetGroupId = gRows[0].id;
    }

    if (!targetGroupId) {
      return res.status(400).json({ status: 'gagal', message: 'Anda belum tergabung dalam grup riset di kelas ini' });
    }

    const id = uuidv4();
    const fileUrl = `/uploads/documents/${filename}`;
    const studentId = String(req.user.id);
    const [uRows] = await pool.query('SELECT full_name, nim FROM users WHERE id = ?', [studentId]);
    const studentName = uRows[0]?.full_name || req.user.full_name || req.user.name || 'Mahasiswa';
    const studentNim = uRows[0]?.nim || req.user.nim || '-';
    let finalDocType = (doc_type && doc_type.trim()) ? doc_type.trim().toLowerCase() : '';
    if (!finalDocType || finalDocType === 'lks') {
      const lowerName = document_name.toLowerCase();
      if (lowerName.includes('cd')) finalDocType = 'cd';
      else if (lowerName.includes('proposal')) finalDocType = 'proposal';
      else if (lowerName.includes('laporan') || lowerName.includes('ta') || lowerName.includes('tugas akhir')) finalDocType = 'laporan_ta';
      else if (lowerName.includes('paper') || lowerName.includes('jurnal') || lowerName.includes('publikasi') || lowerName.includes('artikel')) finalDocType = 'paper';
      else if (!finalDocType) finalDocType = 'lks';
    }

    await pool.query(
      `INSERT INTO research_documents (id, class_id, group_id, student_id, student_name, document_name, doc_type, file_url, deadline, status)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending')`,
      [id, classId, targetGroupId, studentId, studentName, document_name.trim(), finalDocType, fileUrl, deadline]
    );

    const [created] = await pool.query(`
      SELECT rd.*, 
             COALESCE(NULLIF(u.full_name, ''), NULLIF(rd.student_name, ''), 'Mahasiswa') AS student_name,
             COALESCE(NULLIF(u.nim, ''), '-') AS student_nim,
             u.full_name AS student_full_name,
             u.avatar_url AS student_avatar, u.email AS student_email,
             rg.group_name, rg.group_number, rg.title AS group_title
      FROM research_documents rd
      LEFT JOIN research_groups rg ON rg.id = rd.group_id
      LEFT JOIN users u ON u.id = rd.student_id
      WHERE rd.id = ?
    `, [id]);
    const doc = created[0] || {};

    try {
      const io = req.app.get('io');
      if (io) {
        io.emit('research_document_submitted', doc);
        io.to(`session_${classId}`).emit('research_document_submitted', doc);
      }
    } catch (_) {}

    res.status(201).json({
      status: 'sukses',
      message: 'Dokumen berhasil diunggah dan menunggu persetujuan dosen',
      document: doc,
    });
  } catch (error) {
    console.error('UPLOAD RESEARCH DOCUMENT ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 9b. PUT Edit Dokumen untuk Approval (Hanya Mahasiswa, Dosen Tidak Bisa)
router.put('/research-documents/:docId', verifyToken, optionalUploadDoc, async (req, res) => {
  try {
    if (req.user.role === 'dosen') {
      return res.status(403).json({
        status: 'gagal',
        message: 'Dosen tidak dapat mengedit dokumen approval.',
      });
    }

    const { docId } = req.params;
    const { document_name, deadline, doc_type } = req.body;

    const [docs] = await pool.query('SELECT * FROM research_documents WHERE id = ?', [docId]);
    if (docs.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Dokumen tidak ditemukan' });
    }
    const doc = docs[0];

    // Cek apakah mahasiswa yang mengedit berhak (pemilik/anggota grup)
    const userId = String(req.user.id);
    const [isMember] = await pool.query(
      'SELECT 1 FROM research_group_members WHERE group_id = ? AND student_id = ?',
      [doc.group_id, userId]
    );
    if (doc.student_id !== userId && isMember.length === 0) {
      return res.status(403).json({ status: 'gagal', message: 'Anda tidak memiliki hak untuk mengedit dokumen grup ini' });
    }

    let fileUrl = doc.file_url;
    if (req.file) {
      fileUrl = `/uploads/documents/${req.file.filename}`;
    } else if (req.body && (req.body.file_base64 || req.body.document_base64)) {
      const rawBase64 = req.body.file_base64 || req.body.document_base64;
      const matches = rawBase64.match(/^data:([A-Za-z-+\/]+);base64,(.+)$/);
      let buffer;
      let ext = '.pdf';
      if (req.body.filename && path.extname(req.body.filename)) {
        ext = path.extname(req.body.filename).toLowerCase();
      }
      if (matches && matches.length === 3) {
        buffer = Buffer.from(matches[2], 'base64');
      } else {
        buffer = Buffer.from(rawBase64, 'base64');
      }
      const filename = `doc-${Date.now()}-${uuidv4()}${ext}`;
      fs.writeFileSync(path.join(docDir, filename), buffer);
      fileUrl = `/uploads/documents/${filename}`;
    }

    const updatedDocName = (document_name && document_name.trim()) ? document_name.trim() : doc.document_name;
    const updatedDeadline = (deadline && deadline.trim()) ? deadline.trim() : doc.deadline;
    const updatedDocType = (doc_type && doc_type.trim()) ? doc_type.trim().toLowerCase() : (doc.doc_type || 'lks');

    // Jika dokumen berstatus rejected dan diedit oleh mahasiswa, kembalikan status ke pending agar dapat direview kembali
    let newStatus = doc.status;
    if (doc.status === 'rejected') {
      newStatus = 'pending';
    }

    await pool.query(
      `UPDATE research_documents 
       SET document_name = ?, doc_type = ?, deadline = ?, file_url = ?, status = ?, updated_at = NOW() 
       WHERE id = ?`,
      [updatedDocName, updatedDocType, updatedDeadline, fileUrl, newStatus, docId]
    );

    const [updated] = await pool.query('SELECT * FROM research_documents WHERE id = ?', [docId]);
    const updatedDoc = updated[0];

    try {
      const io = req.app.get('io');
      if (io) {
        io.emit('research_document_updated', updatedDoc);
        io.to(`session_${doc.class_id}`).emit('research_document_updated', updatedDoc);
      }
    } catch (_) {}

    res.json({
      status: 'sukses',
      message: 'Dokumen berhasil diperbarui',
      document: updatedDoc,
    });
  } catch (error) {
    console.error('UPDATE RESEARCH DOCUMENT ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 9c. DELETE Dokumen Approval (Hanya Dosen yang Bisa Menghapus, Mahasiswa Tidak Bisa)
router.delete('/research-documents/:docId', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'dosen') {
      return res.status(403).json({
        status: 'gagal',
        message: 'Mahasiswa tidak dapat menghapus dokumen approval. Penghapusan dokumen hanya dapat dilakukan oleh Dosen.',
      });
    }

    const { docId } = req.params;
    const [docs] = await pool.query('SELECT * FROM research_documents WHERE id = ?', [docId]);
    if (docs.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Dokumen tidak ditemukan' });
    }
    const doc = docs[0];

    // Hapus file fisik jika ada
    try {
      if (doc.file_url) {
        const filePath = path.join(__dirname, '..', doc.file_url.startsWith('/') ? doc.file_url.substring(1) : doc.file_url);
        if (fs.existsSync(filePath)) fs.unlinkSync(filePath);
      }
      if (doc.signed_file_url) {
        const signedFilePath = path.join(__dirname, '..', doc.signed_file_url.startsWith('/') ? doc.signed_file_url.substring(1) : doc.signed_file_url);
        if (fs.existsSync(signedFilePath)) fs.unlinkSync(signedFilePath);
      }
    } catch (fErr) {
      console.warn('Delete document file warning:', fErr.message);
    }

    await pool.query('DELETE FROM research_documents WHERE id = ?', [docId]);

    try {
      const io = req.app.get('io');
      if (io) {
        const payload = { id: docId, class_id: doc.class_id };
        io.emit('research_document_deleted', payload);
        io.to(`session_${doc.class_id}`).emit('research_document_deleted', payload);
      }
    } catch (_) {}

    res.json({
      status: 'sukses',
      message: 'Dokumen approval berhasil dihapus oleh Dosen',
    });
  } catch (error) {
    console.error('DELETE RESEARCH DOCUMENT ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 10. PUT Dosen Review Dokumen (Approve dengan stempel TTD otomatis atau Tolak/Minta Revisi)
router.put('/research-documents/:docId/review', verifyToken, async (req, res) => {
  try {
    if (req.user.role !== 'dosen') {
      return res.status(403).json({ status: 'gagal', message: 'Hanya dosen yang dapat mereview dokumen' });
    }
    const { docId } = req.params;
    const { action, notes, sign } = req.body; // action: 'approve' atau 'reject', sign: true/false (default true)

    const [docs] = await pool.query(
      `SELECT rd.*, rg.group_name, rg.title AS group_title, c.dosen_id, u.full_name AS dosen_full_name, u.signature_url AS dosen_signature_url, u.nidn_nip AS dosen_nidn_nip
       FROM research_documents rd
       JOIN research_groups rg ON rg.id = rd.group_id
       JOIN quizizz_classes c ON c.id = rd.class_id
       JOIN users u ON u.id = c.dosen_id
       WHERE rd.id = ?`,
      [docId]
    );
    if (docs.length === 0) {
      return res.status(404).json({ status: 'gagal', message: 'Dokumen tidak ditemukan' });
    }
    const doc = docs[0];

    if (action === 'reject') {
      const revisionNote = (notes && notes.trim()) ? notes.trim() : 'Perlu revisi sesuai catatan dosen';
      await pool.query(
        `UPDATE research_documents SET status = 'rejected', notes = ?, updated_at = NOW() WHERE id = ?`,
        [revisionNote, docId]
      );

      try {
        const io = req.app.get('io');
        if (io) {
          const payload = {
            id: docId,
            class_id: doc.class_id,
            group_id: doc.group_id,
            document_name: doc.document_name,
            status: 'rejected',
            notes: revisionNote,
          };
          io.emit('research_document_reviewed', payload);
          io.to(`session_${doc.class_id}`).emit('research_document_reviewed', payload);
        }
      } catch (_) {}

      return res.json({
        status: 'sukses',
        message: 'Dokumen ditolak dan diminta revisi dengan catatan dosen',
        document: { ...doc, status: 'rejected', notes: revisionNote },
      });
    }

    if (action === 'approve') {
      const shouldSign = sign !== false && action !== 'approve_no_sign';

      if (shouldSign) {
        // Validasi dosen sudah unggah tanda tangan di profil
        if (!doc.dosen_signature_url) {
          return res.status(400).json({
            status: 'gagal',
            message: 'Tanda tangan digital dosen belum diunggah di profil. Silakan unggah tanda tangan PNG terlebih dahulu di profil Anda.',
          });
        }
      }

      let signedFileUrl = null;

      if (shouldSign) {
        try {
          const originalFilePath = path.join(__dirname, '..', doc.file_url);
          const sigFilePath = path.join(__dirname, '..', doc.dosen_signature_url);

          if (fs.existsSync(originalFilePath) && fs.existsSync(sigFilePath)) {
            const isPdf = originalFilePath.toLowerCase().endsWith('.pdf');
            let pdfDoc;

            if (isPdf) {
              const originalBytes = fs.readFileSync(originalFilePath);
              pdfDoc = await PDFDocument.load(originalBytes, { ignoreEncryption: true });

              // Deteksi koordinat letak tanda tangan menggunakan pdfjs-dist
              let targetPageIndex = -1;
              let pembimbing1Item = null;
              let pembimbing2Item = null;
              let tandaTanganP1 = null;
              let tanggalP1 = null;
              let bandungItem = null;
              let dosenItem = null;
              let namaItem = null;
              let nipItem = null;
              let pageItems = [];

              try {
                const pdfjsLib = await import('pdfjs-dist/legacy/build/pdf.mjs');
                const data = new Uint8Array(originalBytes);
                const pdfJsDoc = await pdfjsLib.getDocument({ data }).promise;

                // Pass 1: Prioritaskan mencari halaman tabel Lembar Pengesahan (Pembimbing 1 / Pembimbing 2)
                for (let pageNum = 1; pageNum <= pdfJsDoc.numPages; pageNum++) {
                  const page = await pdfJsDoc.getPage(pageNum);
                  const content = await page.getTextContent();
                  const items = content.items;

                  let p1 = null, p2 = null;
                  let ttItems = [];
                  let tglItems = [];

                  for (const item of items) {
                    if (!item.str) continue;
                    const str = item.str.trim();
                    const lower = str.toLowerCase();

                    if (lower.includes('pembimbing 1') || lower.includes('pembimbing i') || lower.includes('pembimbing utama')) {
                      p1 = item;
                    }
                    if (lower.includes('pembimbing 2') || lower.includes('pembimbing ii') || lower.includes('pembimbing pendamping')) {
                      p2 = item;
                    }
                    if (lower.includes('tanda tangan') || lower === 'ttd') {
                      ttItems.push(item);
                    }
                    if (lower.startsWith('tanggal') || lower === 'tgl') {
                      tglItems.push(item);
                    }
                  }

                  if (p1 || p2) {
                    targetPageIndex = pageNum - 1;
                    pembimbing1Item = p1;
                    pembimbing2Item = p2;
                    pageItems = items;

                    if (p1) {
                      const p1Y = p1.transform[5];
                      const p2Y = p2 ? p2.transform[5] : (p1Y - 80);
                      tandaTanganP1 = ttItems.find(t => t.transform[5] <= p1Y + 5 && t.transform[5] > p2Y && t.transform[4] > 250);
                      tanggalP1 = tglItems.find(t => t.transform[5] <= p1Y + 5 && t.transform[5] > p2Y);
                    }
                    break;
                  }
                }

                // Pass 2: Jika bukan format tabel Pembimbing, cari blok tanda tangan tunggal (Bandung, Dosen Pengusul, Nama/NIP)
                if (targetPageIndex < 0) {
                  for (let pageNum = pdfJsDoc.numPages; pageNum >= 1; pageNum--) {
                    const page = await pdfJsDoc.getPage(pageNum);
                    const content = await page.getTextContent();
                    const items = content.items;

                    let bItem = null, dItem = null, nItem = null, pItem = null;
                    for (const item of items) {
                      if (!item.str) continue;
                      const str = item.str.trim();
                      const lower = str.toLowerCase();
                      if (lower.startsWith('bandung,') || lower.startsWith('bandung ,') || (lower.startsWith('bandung') && /\d/.test(str))) bItem = item;
                      if ((lower.includes('dosen pengusul') || lower.includes('dosen pembimbing') || lower.includes('pengusul') || lower.includes('pembimbing')) && str.length < 40) dItem = item;
                      if (lower.startsWith('nama:') || lower.startsWith('nama :') || lower === 'nama') nItem = item;
                      if (lower.startsWith('nip:') || lower.startsWith('nip :') || lower.startsWith('nidn:') || lower.startsWith('nidn :')) pItem = item;
                    }

                    if (bItem || dItem || (nItem && pItem)) {
                      targetPageIndex = pageNum - 1;
                      bandungItem = bItem;
                      dosenItem = dItem;
                      namaItem = nItem;
                      nipItem = pItem;
                      pageItems = items;
                      break;
                    }
                  }
                }
              } catch (scanErr) {
                console.warn('PDF signature location detection warning:', scanErr.message);
              }

              // Check whether Nama or NIP are already populated in the PDF template
              let namaAlreadyFilled = false;
              if (namaItem) {
                const str = namaItem.str.trim();
                if (str.length > 8 && !str.endsWith(':')) {
                  namaAlreadyFilled = true;
                } else {
                  const ny = namaItem.transform[5];
                  const nx = namaItem.transform[4];
                  for (const it of pageItems) {
                    if (!it.str || it === namaItem) continue;
                    const iy = it.transform[5];
                    const ix = it.transform[4];
                    if (Math.abs(iy - ny) <= 6 && ix > nx + 5 && it.str.trim().length > 0) {
                      namaAlreadyFilled = true;
                      break;
                    }
                  }
                }
              }

              let nipAlreadyFilled = false;
              if (nipItem) {
                const str = nipItem.str.trim();
                if (str.length > 6 && !str.endsWith(':')) {
                  nipAlreadyFilled = true;
                } else {
                  const py = nipItem.transform[5];
                  const px = nipItem.transform[4];
                  for (const it of pageItems) {
                    if (!it.str || it === nipItem) continue;
                    const iy = it.transform[5];
                    const ix = it.transform[4];
                    if (Math.abs(iy - py) <= 6 && ix > px + 5 && it.str.trim().length > 0) {
                      nipAlreadyFilled = true;
                      break;
                    }
                  }
                }
              }

              const pageIndex = targetPageIndex >= 0 ? targetPageIndex : (pdfDoc.getPageCount() - 1);
              const targetPage = pdfDoc.getPage(pageIndex);
              const { width: pWidth, height: pHeight } = targetPage.getSize();

              const sigBytes = fs.readFileSync(sigFilePath);
              const embeddedSig = await pdfDoc.embedPng(sigBytes);
              const fontRegular = await pdfDoc.embedFont(StandardFonts.Helvetica);
              const fontBold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);

              const months = ['Januari', 'Februari', 'Maret', 'April', 'Mei', 'Juni', 'Juli', 'Agustus', 'September', 'Oktober', 'November', 'Desember'];
              const now = new Date();
              const dateStr = `${now.getDate()} ${months[now.getMonth()]} ${now.getFullYear()}`;
              const shortDateStr = `${String(now.getDate()).padStart(2, '0')}/${String(now.getMonth() + 1).padStart(2, '0')}/${now.getFullYear()}`;
              const lecturerName = doc.dosen_full_name || req.user.full_name || 'Dr. GELAR BUDIMAN S.T., M.T.';
              const lecturerNip = doc.dosen_nidn_nip || req.user.nidn_nip || '08780030';

              let sigX = 75;
              let sigY = 195;
              let sigW = 170;
              let sigH = 82.5;

              if (pembimbing1Item) {
                // Dokumen dengan format tabel (seperti CD / Lembar Pengesahan)
                const p1Y = pembimbing1Item.transform[5];
                const p1X = pembimbing1Item.transform[4];
                const p2Y = pembimbing2Item ? pembimbing2Item.transform[5] : (p1Y - 57);

                // Posisi X di sebelah kanan, di dalam kotak kolom Tanda Tangan Pembimbing 1 (x: 338..520)
                sigX = 355;
                sigW = 140;
                sigH = 68;
                // Posisi Y persis di atas garis pembatas / teks Pembimbing 2 (y > 252) sehingga berimpit dengan Tanda Tangan & Pembimbing 1 tanpa mengenai Pembimbing 2
                sigY = p2Y > 0 ? (p2Y + 1.7) : 253.5;

                // Tulis Tanggal di samping "Tanggal :" pada baris Pembimbing 1
                if (tanggalP1) {
                  const tglX = tanggalP1.transform[4];
                  const tglY = tanggalP1.transform[5];
                  targetPage.drawText(shortDateStr, {
                    x: tglX + 50,
                    y: tglY,
                    size: 9,
                    font: fontRegular,
                    color: rgb(0, 0, 0),
                  });
                }

                // Ganti format dd/mm/yyyy pada kolom Tanggal Pengesahan jika ada di tabel atas
                for (const item of pageItems) {
                  if (item.str && item.str.toLowerCase().includes('dd/mm/yyyy')) {
                    targetPage.drawRectangle({
                      x: item.transform[4] - 1,
                      y: item.transform[5] - 1,
                      width: Math.max(item.width || 60, 65),
                      height: 12,
                      color: rgb(1, 1, 1),
                    });
                    targetPage.drawText(shortDateStr, {
                      x: item.transform[4],
                      y: item.transform[5],
                      size: 9,
                      font: fontRegular,
                      color: rgb(0, 0, 0),
                    });
                  }
                }

              } else {
                // Dokumen format standar
                // 1. Tulis Tanggal Bandung
                if (bandungItem) {
                  const bx = bandungItem.transform[4];
                  const by = bandungItem.transform[5];
                  targetPage.drawRectangle({
                    x: bx,
                    y: by - 2,
                    width: Math.max(bandungItem.width || 0, 240),
                    height: 14,
                    color: rgb(1, 1, 1),
                  });
                  targetPage.drawText(`Bandung, ${dateStr}`, {
                    x: bx,
                    y: by,
                    size: 10,
                    font: fontRegular,
                    color: rgb(0, 0, 0),
                  });
                }

                // 2. Tulis Nama Dosen HANYA jika belum ada di dokumen asli
                if (namaItem && !namaAlreadyFilled) {
                  const nx = namaItem.transform[4];
                  const ny = namaItem.transform[5];
                  targetPage.drawText(` ${lecturerName}`, {
                    x: nx + (namaItem.width || 30) + 4,
                    y: ny,
                    size: 10,
                    font: fontRegular,
                    color: rgb(0, 0, 0),
                  });
                }

                // 3. Tulis NIP Dosen HANYA jika belum ada di dokumen asli
                if (nipItem && !nipAlreadyFilled) {
                  const px = nipItem.transform[4];
                  const py = nipItem.transform[5];
                  targetPage.drawText(` ${lecturerNip}`, {
                    x: px + (nipItem.width || 25) + 4,
                    y: py,
                    size: 10,
                    font: fontRegular,
                    color: rgb(0, 0, 0),
                  });
                }

                // 4. Tempatkan Gambar Tanda Tangan PNG
                if (namaItem) {
                  sigX = namaItem.transform[4] - 8;
                  sigY = namaItem.transform[5] - 16;
                } else if (dosenItem) {
                  sigX = dosenItem.transform[4] - 20;
                  sigY = dosenItem.transform[5] - 85;
                } else if (bandungItem) {
                  sigX = bandungItem.transform[4];
                  sigY = bandungItem.transform[5] - 95;
                } else {
                  sigX = pWidth - 220;
                  sigY = 50;
                  targetPage.drawText(`Bandung, ${dateStr}`, { x: sigX, y: sigY + 120, size: 10, font: fontRegular });
                  targetPage.drawText('Dosen Pembimbing / Penilai,', { x: sigX, y: sigY + 105, size: 10, font: fontRegular });
                  if (!namaAlreadyFilled) targetPage.drawText(lecturerName, { x: sigX, y: sigY - 5, size: 10, font: fontBold });
                  if (!nipAlreadyFilled) targetPage.drawText(`NIP: ${lecturerNip}`, { x: sigX, y: sigY - 18, size: 9, font: fontRegular });
                }
              }

              targetPage.drawImage(embeddedSig, {
                x: sigX,
                y: sigY,
                width: sigW,
                height: sigH,
              });

            } else {
              // Jika dokumen asli bukan PDF (misal DOCX), buat PDF approval certificate baru
              pdfDoc = await PDFDocument.create();
              const sigBytes = fs.readFileSync(sigFilePath);
              const embeddedSig = await pdfDoc.embedPng(sigBytes);
              const fontBold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
              const fontRegular = await pdfDoc.embedFont(StandardFonts.Helvetica);

              const page = pdfDoc.addPage([595.28, 841.89]);
              const { width, height } = page.getSize();

              page.drawRectangle({
                x: 40,
                y: height - 110,
                width: width - 80,
                height: 70,
                color: rgb(0 / 255, 29 / 255, 57 / 255),
              });
              page.drawText('LEMBAR PENGESAHAN DOKUMEN DIGITAL', {
                x: 60,
                y: height - 70,
                size: 15,
                font: fontBold,
                color: rgb(1, 1, 1),
              });

              const sigBoxX = width - 260;
              const sigBoxY = height - 570;
              page.drawText(`Bandung, ${new Date().toLocaleDateString('id-ID', { year: 'numeric', month: 'long', day: 'numeric' })}`, {
                x: sigBoxX,
                y: sigBoxY + 130,
                size: 10,
                font: fontRegular,
                color: rgb(0, 0, 0),
              });
              page.drawImage(embeddedSig, {
                x: sigBoxX,
                y: sigBoxY + 5,
                width: 170,
                height: 82.5,
              });
              page.drawText(String(doc.dosen_full_name || req.user.name || 'Dosen'), {
                x: sigBoxX,
                y: sigBoxY + 10,
                size: 10,
                font: fontBold,
                color: rgb(0, 0, 0),
              });
            }

            const signedPdfBytes = await pdfDoc.save();
            const signedFilename = `signed-${Date.now()}-${uuidv4()}.pdf`;
            const signedFilePath = path.join(__dirname, '..', 'uploads', 'documents', signedFilename);
            fs.writeFileSync(signedFilePath, signedPdfBytes);
            signedFileUrl = `/uploads/documents/${signedFilename}`;
          }
        } catch (pdfErr) {
          console.error('PDF SIGNING ERROR:', pdfErr);
        }
      }

      const defaultApproveNote = shouldSign ? 'Disetujui dan ditandatangani oleh Dosen' : 'Disetujui oleh Dosen';
      const approveNote = (notes && notes.trim()) ? notes.trim() : defaultApproveNote;
      await pool.query(
        `UPDATE research_documents SET status = 'approved', signed_file_url = ?, approved_at = NOW(), notes = ?, updated_at = NOW() WHERE id = ?`,
        [signedFileUrl, approveNote, docId]
      );

      try {
        const io = req.app.get('io');
        if (io) {
          const payload = {
            id: docId,
            class_id: doc.class_id,
            group_id: doc.group_id,
            document_name: doc.document_name,
            status: 'approved',
            signed_file_url: signedFileUrl,
            notes: approveNote,
          };
          io.emit('research_document_reviewed', payload);
          io.to(`session_${doc.class_id}`).emit('research_document_reviewed', payload);
        }
      } catch (_) {}

      return res.json({
        status: 'sukses',
        message: shouldSign ? 'Dokumen berhasil disetujui dan ditandatangani secara digital' : 'Dokumen berhasil disetujui',
        signed_file_url: signedFileUrl,
        document: { ...doc, status: 'approved', signed_file_url: signedFileUrl, notes: approveNote, approved_at: new Date() },
      });
    }
  } catch (error) {
    console.error('REVIEW RESEARCH DOCUMENT ERROR:', error);
    res.status(500).json({ status: 'gagal', message: error.message });
  }
});

// 11. GET Download File Dokumen / Riset dengan header attachment resmi
router.get('/download-file', (req, res) => {
  try {
    const fileUrl = req.query.url;
    const downloadName = req.query.name || 'dokumen.pdf';
    if (!fileUrl) {
      return res.status(400).send('File url wajib disertakan');
    }
    const cleanPath = fileUrl.startsWith('/') ? fileUrl.substring(1) : fileUrl;
    const fullPath = path.join(__dirname, '..', cleanPath);
    if (!fs.existsSync(fullPath)) {
      return res.status(404).send('File tidak ditemukan di server');
    }
    res.setHeader('Content-Type', 'application/pdf');
    res.setHeader('Content-Disposition', `attachment; filename="${encodeURIComponent(downloadName)}"`);
    res.sendFile(fullPath);
  } catch (err) {
    res.status(500).send(err.message);
  }
});

module.exports = router;