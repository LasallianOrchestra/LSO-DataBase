/* Synthetic but realistic LSO dataset used to exercise the real app code paths. */
const FIRST = ['Andres', 'Maria', 'Jose', 'Juan', 'Beatriz', 'Carlo', 'Danica', 'Emmanuel', 'Francesca', 'Gabriel', 'Hannah', 'Ignacio', 'Jasmine', 'Kirk', 'Lorenzo', 'Miguel', 'Nathaniel', 'Olivia', 'Patricia', 'Quentin', 'Rafael', 'Sofia', 'Timothy', 'Ulysses', 'Victoria', 'Wilfredo', 'Xander', 'Ysabel', 'Zachary', 'Kirsten'];
const LAST = ['Dela Cruz', 'Santos-Reyes', 'Villanueva', 'Bautista', 'Ocampo', 'Mendoza', 'Aguinaldo', 'Rizalino', 'Castillejos', 'Fernandez', 'Gonzales', 'Hidalgo', 'Ilagan', 'Javier', 'Kalaw', 'Lacsamana', 'Mabini', 'Nakpil', 'Oteyza', 'Panganiban', 'Quebral', 'Ramos-Sison', 'Salvacion', 'Tiangco', 'Umali', 'Valenzuela', 'Wenceslao', 'Yaptinchay', 'Zabala', 'Asuncion'];
const SECTIONS = ['Violin I', 'Violin II', 'Viola', 'Cello', 'Double Bass', 'Woodwinds', 'Brass', 'Percussion', 'Piano & Harp'];
const INSTRUMENTS = ['Violin', 'Viola', 'Cello', 'Double Bass', 'Clarinet in B-flat', 'Bass Clarinet', 'French Horn in F', 'Trumpet in B-flat', 'Tenor Trombone', 'Bass Trombone', 'Tuba', 'Snare Drum', 'Marimba', 'Concert Harp', 'Flute', 'Oboe', 'Bassoon', 'Timpani'];
const COURSES = ['BS Civil Engineering', 'BS Computer Engineering', 'AB Communication', 'BS Accountancy', 'BS Psychology', 'BS Management Engineering', 'AB Political Science', 'BS Electronics & Communications Engineering'];
const ORG_POSITIONS = ['', 'Concertmaster', 'Section Principal', 'Assistant Principal', 'Orchestra Council Member', ''];
const STATUSES = ['Active', 'Active', 'Active', 'On Leave', 'Inactive', 'Active'];

function iso(date) { return date.toISOString().slice(0, 10); }
function pick(arr, i) { return arr[i % arr.length]; }

const members = [];
const today = new Date('2026-09-13T00:00:00Z');
for (let i = 0; i < 34; i++) {
  const first = pick(FIRST, i * 3 + 1);
  const last = pick(LAST, i * 5 + 2);
  const fullName = `${last}, ${first} ${pick(['A.', 'B.', 'C.', 'D.', 'E.', ''], i)}`.replace(/\s+$/, '');
  const registered = new Date(today.getTime() - (400 + i * 47) * 86400000);
  const traineeStart = new Date(registered.getTime() + 30 * 86400000);
  const probStart = new Date(traineeStart.getTime() + (i % 4 === 0 ? 0 : 180) * 86400000);
  const regular = new Date(probStart.getTime() + 365 * 86400000);
  const periodGroup = i % 3 === 0 ? 'Trainee Period' : i % 3 === 1 ? 'Probationary Period' : 'Membership Period';
  members.push({
    id: `mem-${1000 + i}`,
    membershipId: `LSO-2026-${String(101 + i)}`,
    fullName,
    outlook: `${first.toLowerCase().replace(/[^a-z]/g, '')}.${last.toLowerCase().replace(/[^a-z]/g, '').slice(0, 10)}@dlsu.edu.ph`,
    studentNumber: `1${String(20 + (i % 6))}${String(10000 + i * 137).slice(0, 5)}`,
    orchestraSection: pick(SECTIONS, i),
    primaryInstrument: pick(INSTRUMENTS, i * 2),
    secondaryInstrument: i % 5 === 0 ? pick(INSTRUMENTS, i + 7) : '',
    organizationPosition: pick(ORG_POSITIONS, i),
    organizationRole: i % 6 === 0 ? 'Membership Committee' : i % 7 === 0 ? 'Logistics Committee' : '',
    course: pick(COURSES, i),
    cys: `${2023 + (i % 4)}-${2024 + (i % 4)}`,
    yearLevel: `${(i % 4) + 1}`,
    memberStatus: pick(STATUSES, i),
    membershipStage: periodGroup === 'Membership Period' ? 'Regular Member' : periodGroup === 'Probationary Period' ? 'Probationary' : 'Trainee/Probationary',
    periodGroup,
    dateRegistered: iso(registered),
    traineeStartDate: iso(traineeStart),
    probationaryStartDate: periodGroup === 'Trainee Period' ? '' : iso(probStart),
    regularMemberDate: periodGroup === 'Membership Period' ? iso(regular) : '',
    lastProfileReview: iso(new Date(today.getTime() - (i % 9) * 30 * 86400000)),
    reviewStatus: i % 7 === 0 ? 'Overdue' : i % 5 === 0 ? 'For Review' : 'Current',
    contactNumber: `+63 9${String(170000000 + i * 1234567).slice(0, 9)}`,
    profilePhoto: '',
    notes: i % 4 === 0 ? 'Requires music stand assignment for rehearsal hall A. Also serves on the seasonal programming committee for the upcoming Lasallian Days concert series.' : '',
    probationarySkipped: i % 11 === 0
  });
}

const events = [];
for (let i = 0; i < 12; i++) {
  const d = new Date(today.getTime() + (i - 3) * 6 * 86400000);
  events.push({
    id: `evt-${500 + i}`,
    title: pick(['General Rehearsal', 'Sectionals — Strings', 'Full Orchestra Run-Through', 'Lasallian Days Concert', 'Chamber Night', 'Recording Session', 'Uniform & Instrument Inspection'], i),
    date: iso(d),
    startTime: `${String(15 + (i % 4)).padStart(2, '0')}:00`,
    endTime: `${String(18 + (i % 3)).padStart(2, '0')}:00`,
    venue: pick(['Henry Sy Sr. Hall', 'DLSU Auditorium', 'Music Rehearsal Room 304', 'St. La Salle Hall Foyer'], i),
    type: pick(['Rehearsal', 'Performance', 'Administrative'], i),
    requiredSections: i % 3 === 0 ? SECTIONS : SECTIONS.slice(0, 4),
    notes: i % 4 === 0 ? 'Formal concert attire required. Call time is 30 minutes before downbeat.' : ''
  });
}

const instruments = [];
for (let i = 0; i < 18; i++) {
  instruments.push({
    id: `ins-${300 + i}`,
    name: INSTRUMENTS[i % INSTRUMENTS.length],
    category: i % 4 === 0 ? 'Strings' : i % 4 === 1 ? 'Woodwinds' : i % 4 === 2 ? 'Brass' : 'Percussion',
    quantity: 1 + (i % 6),
    condition: pick(['Excellent', 'Good', 'Needs Repair'], i),
    assignedTo: i % 3 === 0 ? members[i].fullName : '',
    serialNumber: `LSO-INS-${String(4000 + i * 13)}`,
    notes: i % 5 === 0 ? 'Owned by the university; requires annual inventory check.' : ''
  });
}

// Duty hours: { version, commitments, entries, archiveExclusions }
const SEMESTERS = ['AY 2026-2027 Term 1', 'AY 2025-2026 Term 3'];
const PERIODS = ['August 2026', 'September 2026', 'July 2026'];
const entries = [];
for (let i = 0; i < 90; i++) {
  const member = members[i % members.length];
  const d = new Date(today.getTime() - (i % 45) * 86400000);
  const type = i % 6 === 0 ? 'Incentive' : 'Duty';
  const approval = i % 8 === 0 ? 'Pending' : i % 13 === 0 ? 'Rejected' : 'Approved';
  entries.push({
    id: `duty-${9000 + i}`,
    memberId: member.id,
    memberName: member.fullName,
    semester: SEMESTERS[i % 5 === 0 ? 1 : 0],
    period: PERIODS[i % 3],
    date: iso(d),
    entryType: type,
    minutes: type === 'Incentive' ? 60 * (1 + (i % 3)) : 30 * (2 + (i % 5)),
    hours: null,
    timeIn: type === 'Duty' ? `${String(14 + (i % 5)).padStart(2, '0')}:00` : '',
    timeOut: type === 'Duty' ? `${String(18 + (i % 3)).padStart(2, '0')}:${i % 2 ? '30' : '00'}` : '',
    approvalStatus: approval,
    timeInApprovalStatus: approval === 'Approved' ? 'Approved' : approval === 'Pending' ? 'Pending' : 'Approved',
    timeOutApprovalStatus: approval === 'Approved' ? 'Approved' : approval === 'Pending' ? 'Not Submitted' : 'Rejected',
    description: type === 'Incentive' ? 'Concert service credit' : 'Rehearsal duty — section call',
    submittedAt: iso(d) + 'T18:05:00',
    requiredApprover: 'General Secretary'
  });
}
const commitments = {};
members.slice(0, 20).forEach((m, i) => { commitments[m.id] = { hours: 24 + (i % 8) * 6, semester: SEMESTERS[0] }; });
const dutyHours = { version: 8, commitments, entries, archiveExclusions: {} };

const activityLog = [];
for (let i = 0; i < 25; i++) {
  activityLog.push({
    id: `act-${i}`,
    action: pick(['Updated member', 'Approved duty punch', 'Finalized attendance', 'Generated contract', 'Registered member'], i),
    module: pick(['Members', 'Duty Hours', 'Attendance', 'Contracts'], i),
    detail: `${members[i % members.length].fullName} (${members[i % members.length].membershipId})`,
    actor: 'Administrator Test',
    role: 'Administrator',
    timestamp: new Date(today.getTime() - i * 3600000).toISOString()
  });
}

const accounts = [
  { id: 'acc-1', username: 'lso.admin', displayName: 'Amadeus Testado', email: 'amadeus.admin@dlsu.edu.ph', role: 'Administrator', memberId: members[0].id, approvalStatus: 'Approved', disabled: false, isDefault: true, createdAt: '2025-01-04', approvedAt: '2025-01-04', lastLoginAt: '2026-09-12' },
  { id: 'acc-2', username: 'gen.secretaire', displayName: 'Beatriz Lacsamana', email: 'beatriz.lacsamana@dlsu.edu.ph', role: 'General Secretary', memberId: members[1].id, approvalStatus: 'Approved', disabled: false, isDefault: false, createdAt: '2025-02-11', approvedAt: '2025-02-12', lastLoginAt: '2026-09-11' },
  { id: 'acc-3', username: 'membership.officer', displayName: 'Carlo Ocampo', email: 'carlo.ocampo@dlsu.edu.ph', role: 'Membership', memberId: members[2].id, approvalStatus: 'Approved', disabled: false, isDefault: false, createdAt: '2025-03-02', approvedAt: '2025-03-03', lastLoginAt: '2026-09-09' },
  { id: 'acc-4', username: 'staff.monitor', displayName: 'Danica Hidalgo', email: 'danica.hidalgo@dlsu.edu.ph', role: 'Staff Account', memberId: members[3].id, approvalStatus: 'Approved', disabled: false, isDefault: false, createdAt: '2025-04-19', approvedAt: '2025-04-20', lastLoginAt: '2026-09-08' },
  { id: 'acc-5', username: 'trainee.one', displayName: 'Emmanuel Quebral', email: 'emmanuel.quebral@dlsu.edu.ph', role: 'Trainee/Probationary', memberId: members[4].id, approvalStatus: 'Approved', disabled: false, isDefault: false, createdAt: '2026-06-01', approvedAt: '2026-06-02', lastLoginAt: '2026-09-13' }
];
for (let i = 5; i < 16; i++) {
  accounts.push({
    id: `acc-${i + 1}`, username: `member.account${i}`, displayName: members[i].fullName, email: members[i].outlook,
    role: i % 4 === 0 ? 'Trainee/Probationary' : 'Staff Account', memberId: members[i].id,
    approvalStatus: i % 7 === 0 ? 'Pending' : 'Approved', disabled: i % 11 === 0, isDefault: false,
    createdAt: '2026-07-0' + (i % 9 + 1), approvedAt: i % 7 === 0 ? '' : '2026-07-1' + (i % 8 + 1), lastLoginAt: i % 5 === 0 ? '' : '2026-09-0' + (i % 9 + 1)
  });
}

const settings = {
  lso_semester_current_v1: SEMESTERS[0],
  organizationName: 'Lasallian Symphony Orchestra',
  attendanceFinalization: { lockedPeriods: [] },
  lso_notification_preferences_v69: {}
};

module.exports = {
  members, events, instruments, activityLog, accounts, dutyHours, settings,
  state: {
    members,
    events,
    instruments,
    activity_log: activityLog,
    attendance: {},
    settings,
    duty_hours: dutyHours,
    monthly_reports_compat: {}
  }
};
