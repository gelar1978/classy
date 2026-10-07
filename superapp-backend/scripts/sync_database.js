const fs = require('fs');
const pool = require(fs.existsSync('./db.js') ? './db' : '../db');
const bcrypt = require('bcrypt');
const { v4: uuidv4 } = require('uuid');

async function sync() {
  const jsonPath = fs.existsSync('/tmp/kuis2_data.json') ? '/tmp/kuis2_data.json' : './kuis2_data.json';
  const data = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
  const csvStudents = data.csv_students;
  const matches = data.matches;

  console.log('=== SYNCING TO DATABASE ===');
  
  // 1. Get Stegano Class
  const [classes] = await pool.query("SELECT * FROM quizizz_classes WHERE class_name = 'Stegano' LIMIT 1");
  if (classes.length === 0) {
    throw new Error('Stegano class not found in DB!');
  }
  const steganoClass = classes[0];
  console.log(`Stegano Class ID: ${steganoClass.id}`);

  // 2. Ensure all CSV students are in users & quizizz_class_members
  for (const s of csvStudents) {
    const nim = s.nim;
    const email = `${nim}@student.telkomuniversity.ac.id`;
    const [existingUsers] = await pool.query('SELECT id, nim, full_name FROM users WHERE nim = ? OR email = ?', [nim, email]);
    
    let userId;
    let fullName = s.name;
    if (existingUsers.length === 0) {
      userId = uuidv4();
      const userPassHash = await bcrypt.hash(nim, 10);
      await pool.query(
        `INSERT INTO users (id, full_name, email, password_hash, role, nim, program_studi, angkatan) 
         VALUES (?, ?, ?, ?, 'mahasiswa', ?, 'S1 Teknik Telekomunikasi', '2023')`,
        [userId, fullName, email, userPassHash, nim]
      );
      console.log(`[+] Created user: ${nim} - ${fullName}`);
    } else {
      userId = existingUsers[0].id;
      fullName = existingUsers[0].full_name;
    }

    // Ensure member of Stegano class
    const [existingMembers] = await pool.query(
      'SELECT * FROM quizizz_class_members WHERE class_id = ? AND student_id = ?',
      [steganoClass.id, userId]
    );
    if (existingMembers.length === 0) {
      await pool.query(
        'INSERT INTO quizizz_class_members (id, class_id, student_id, student_name, joined_at) VALUES (?, ?, ?, ?, NOW())',
        [uuidv4(), steganoClass.id, userId, fullName]
      );
      console.log(`[+] Enrolled ${nim} (${fullName}) into class Stegano`);
    }
  }

  // 3. Create or find Kuis Pekan 2 assessment
  const [existingAssessments] = await pool.query(
    "SELECT * FROM class_assessments WHERE class_id = ? AND (title LIKE '%Kuis Pekan 2%' OR title LIKE '%Kuis 2%')",
    [steganoClass.id]
  );
  
  let assessmentId;
  if (existingAssessments.length === 0) {
    assessmentId = uuidv4();
    await pool.query(
      `INSERT INTO class_assessments (id, class_id, title, type, max_score, order_index, created_at)
       VALUES (?, ?, 'Kuis Pekan 2', 'quiz', 100.00, 2, NOW())`,
      [assessmentId, steganoClass.id]
    );
    console.log(`[+] Created assessment 'Kuis Pekan 2' (ID: ${assessmentId})`);
  } else {
    assessmentId = existingAssessments[0].id;
    console.log(`[*] Found existing assessment 'Kuis Pekan 2' (ID: ${assessmentId})`);
  }

  // 4. Upsert student grades for Kuis Pekan 2
  const [allStudents] = await pool.query(
    `SELECT u.id, u.nim, u.full_name 
     FROM users u 
     JOIN quizizz_class_members m ON u.id = m.student_id 
     WHERE m.class_id = ? AND u.role = 'mahasiswa'`,
    [steganoClass.id]
  );

  let updatedCount = 0;
  let insertedCount = 0;

  for (const stu of allStudents) {
    const nim = stu.nim;
    const match = matches[nim] || { score: null, notes: 'Belum Mengerjakan' };
    
    const [existingGrades] = await pool.query(
      'SELECT id FROM class_student_grades WHERE class_id = ? AND assessment_id = ? AND student_id = ?',
      [steganoClass.id, assessmentId, stu.id]
    );

    if (existingGrades.length > 0) {
      await pool.query(
        'UPDATE class_student_grades SET score = ?, notes = ?, nim = ?, updated_at = NOW() WHERE id = ?',
        [match.score, match.notes, nim, existingGrades[0].id]
      );
      updatedCount++;
    } else {
      await pool.query(
        `INSERT INTO class_student_grades (id, class_id, assessment_id, student_id, nim, score, notes, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, NOW(), NOW())`,
        [uuidv4(), steganoClass.id, assessmentId, stu.id, nim, match.score, match.notes]
      );
      insertedCount++;
    }
  }

  console.log(`[✓] Sync done: ${insertedCount} grades inserted, ${updatedCount} grades updated.`);
  
  // Show summary
  const [summary] = await pool.query(`
    SELECT u.nim, u.full_name, g.score, g.notes 
    FROM class_student_grades g 
    JOIN users u ON g.student_id = u.id 
    WHERE g.assessment_id = ? 
    ORDER BY u.nim ASC
  `, [assessmentId]);

  console.log('\n=== REKAP NILAI KUIS PEKAN 2 ===');
  console.log(`Total terdata: ${summary.length}`);
  console.log(`Nilai 100: ${summary.filter(r => r.score == 100).length}`);
  console.log(`Belum Mengerjakan: ${summary.filter(r => r.score == null).length}`);
  
  process.exit(0);
}

sync().catch(err => {
  console.error('Sync error:', err);
  process.exit(1);
});
