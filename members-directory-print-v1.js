/**
 * Members Directory Print v2 - Official LSO Portrait Print with Individual Selection
 * -------------------------------------------------------------------------------
 * Prints members' information for the active directory stage
 * (Membership Period, Probationary Period, Trainee Period) as indicated
 * in system management, using official LSO header and footer,
 * portrait portrait paper (8.5" x 13" / Folio).
 *
 * v2 upgrades over v1:
 * - Individual member selection via checkbox column in the directory table
 * - Per-row print button (print a single member's official record)
 * - Selection modal: choose exactly which filtered members to print
 * - Portrait 8.5in x 13in portrait layout with safe inch margins:
 *     header 1.05in / footer 0.80in
 *     content margins: top 1.30in, sides 0.60in, bottom 1.05in
 * - Professional bordered tables for the summary and every detail section
 *
 * Professional layout:
 * - Official header/footer on every page (fixed repeat)
 * - Portrait @page size (8.5in x 13in portrait)
 * - Each member record includes all system management fields
 * - Profile photo, personal, academic, organization, timeline, remarks
 * - Summary table at start, paginated detailed record tables
 * - Respects current filters and active tab; selection refines the scope
 *
 * Dependencies: LSOBrand (optional), LSO_OFFICIAL_PDF_ASSETS (optional), LSOApp.getMembers()
 */

(() => {
  'use strict';

  // ---------------------------------------------------------------------------
  // Portrait portrait geometry (all values in inches for print safety)
  // ---------------------------------------------------------------------------
  const PAPER_WIDTH_IN = 8.5;
  const PAPER_HEIGHT_IN = 13;
  const HEADER_HEIGHT_IN = 1.05;
  const FOOTER_HEIGHT_IN = 0.80;
  // Safe content margins clear the fixed header/footer with breathing room.
  const MARGIN_TOP_IN = 1.30;
  const MARGIN_SIDE_IN = 0.60;
  const MARGIN_BOTTOM_IN = 1.05;
  const PAPER_LABEL = 'Portrait (8.5" x 13")';

  const STAGE_IDS = {
    'Membership Period': 'memberListMode',
    'Probationary Period': 'probationaryTab',
    'Trainee Period': 'traineeTab'
  };

  const FIELD_DEFINITIONS = [
    // Personal Information
    { section: 'Personal Information', label: 'Full Name', key: 'fullName' },
    { section: 'Personal Information', label: 'Membership ID', key: 'membershipId' },
    { section: 'Personal Information', label: 'Student Number', key: 'studentNumber' },
    { section: 'Personal Information', label: 'Age', key: 'age' },
    { section: 'Personal Information', label: 'Birthdate', key: 'birthdate', type: 'date' },
    { section: 'Personal Information', label: 'Sex', key: 'sex' },
    { section: 'Personal Information', label: 'Home Address', key: 'homeAddress', full: true },
    { section: 'Personal Information', label: 'DLSUD Outlook', key: 'outlook' },
    // Academic
    { section: 'Academic Information', label: 'College', key: 'college' },
    { section: 'Academic Information', label: 'Course', key: 'course' },
    { section: 'Academic Information', label: 'Year Level', key: 'yearLevel' },
    { section: 'Academic Information', label: 'Section', key: 'section' },
    { section: 'Academic Information', label: 'CYS', key: 'cys' },
    { section: 'Academic Information', label: 'Academic Status', key: 'academicStatus' },
    // Organization
    { section: 'Organization Information', label: 'Position in Organization', key: 'organizationPosition' },
    { section: 'Organization Information', label: 'Specific Organization Role', key: 'organizationRole' },
    { section: 'Organization Information', label: 'Member Status', key: 'memberStatus' },
    { section: 'Organization Information', label: 'Membership Stage', key: 'membershipStage' },
    { section: 'Organization Information', label: 'Current Period Group', key: 'periodGroup' },
    { section: 'Organization Information', label: 'Stage Notes', key: 'stageNotes', full: true },
    { section: 'Organization Information', label: 'Orchestra Section', key: 'orchestraSection' },
    { section: 'Organization Information', label: 'Primary Instrument', key: 'primaryInstrument' },
    // Timeline / Record Management
    { section: 'Membership Timeline', label: 'Trainee Period Start', key: 'traineeStartDate', type: 'date' },
    { section: 'Membership Timeline', label: 'Probationary Period Start', key: 'probationaryStartDate', type: 'date' },
    { section: 'Membership Timeline', label: 'Probationary Skipped', key: 'probationarySkipped', type: 'boolean' },
    { section: 'Membership Timeline', label: 'Membership Period Start', key: 'regularMemberDate', type: 'date' },
    { section: 'Membership Timeline', label: 'Date Registered', key: 'dateRegistered', type: 'date' },
    { section: 'Membership Timeline', label: 'Last Profile Review', key: 'lastProfileReview', type: 'date' },
    { section: 'Membership Timeline', label: 'Review Status', key: 'reviewStatus' },
    { section: 'Membership Timeline', label: 'Record Quality', key: 'recordQuality', type: 'percent' },
    { section: 'Record Notes', label: 'Remarks / Notes', key: 'remarks', full: true }
  ];

  const SECTION_ORDER = ['Personal Information', 'Academic Information', 'Organization Information', 'Membership Timeline', 'Record Notes'];
  const SECTION_NUMBERS = {
    'Personal Information': '01',
    'Academic Information': '02',
    'Organization Information': '03',
    'Membership Timeline': '04',
    'Record Notes': '05'
  };

  // ---------------------------------------------------------------------------
  // Selection state (individual member selection for printing)
  // ---------------------------------------------------------------------------
  const selectedIds = new Set();
  let activeStage = 'Membership Period';
  let decorating = false;

  function el(id) { return document.getElementById(id); }

  function inches(value) {
    return `${Number(value).toFixed(2)}in`;
  }

  function safeText(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (c) => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
    }[c]));
  }

  function toDateLabel(value) {
    if (!value) return '—';
    const d = new Date(`${value}T00:00:00`);
    if (Number.isNaN(d.getTime())) return String(value);
    try {
      return new Intl.DateTimeFormat('en-PH', { year: 'numeric', month: 'short', day: 'numeric' }).format(d);
    } catch { return String(value); }
  }

  function todayISO() {
    try {
      const parts = new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Manila', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(new Date());
      const vals = Object.fromEntries(parts.map(p => [p.type, p.value]));
      return `${vals.year}-${vals.month}-${vals.day}`;
    } catch {
      const d = new Date();
      return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
    }
  }

  function currentAccount() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function getMembers() {
    return window.LSOApp?.getMembers?.() || [];
  }

  function getMemberById(id) {
    if (window.LSOApp?.getMemberById) {
      try { return window.LSOApp.getMemberById(id); } catch { /* fall through */ }
    }
    return getMembers().find(m => String(m.id) === String(id)) || null;
  }

  function getCurrentStage() {
    // Check active segmented button
    for (const [stage, id] of Object.entries(STAGE_IDS)) {
      const btn = el(id);
      if (btn && btn.classList.contains('active')) return stage;
    }
    // Fallback to periodGroupFilter
    const filter = el('periodGroupFilter');
    if (filter && filter.value) return filter.value;
    return 'Membership Period';
  }

  function getFilteredMembersForPrint() {
    const all = getMembers();
    const stage = getCurrentStage();
    const search = (el('memberSearch')?.value || '').trim().toLowerCase();
    const status = el('statusFilter')?.value || '';
    const section = el('sectionFilter')?.value || '';
    const position = el('positionFilter')?.value || '';

    return all.filter(member => {
      const haystack = [
        member.membershipId, member.fullName, member.studentNumber, member.outlook,
        member.primaryInstrument, member.organizationRole, member.course,
        member.cys, member.membershipStage, member.periodGroup, member.college,
        member.yearLevel, member.section
      ].join(' ').toLowerCase();

      return member.periodGroup === stage &&
        (!search || haystack.includes(search)) &&
        (!status || member.memberStatus === status) &&
        (!section || member.orchestraSection === section) &&
        (!position || member.organizationPosition === position);
    }).sort((a, b) => String(a.fullName || '').localeCompare(String(b.fullName || '')));
  }

  function getSelectedFilteredMembers() {
    return getFilteredMembersForPrint().filter(m => selectedIds.has(String(m.id)));
  }

  function getOfficialAssetDataUri(name) {
    try {
      const assets = window.LSO_OFFICIAL_PDF_ASSETS || {};
      const raw = assets[name];
      if (raw) {
        const trimmed = String(raw).trim();
        if (trimmed.startsWith('data:')) return trimmed;
        return `data:image/png;base64,${trimmed}`;
      }
    } catch {}
    const brand = window.LSOBrand || {};
    if (name === 'lso-official-header.png') return brand.officialHeaderUrl || 'lso-official-header.png';
    if (name === 'lso-official-footer.png') return brand.officialFooterUrl || 'lso-official-footer.png';
    if (name === 'lso-official-template.png') return brand.officialTemplateUrl || 'lso-official-template.png';
    return name;
  }

  function formatFieldValue(member, def) {
    const raw = member[def.key];
    if (def.type === 'date') {
      if (def.key === 'probationaryStartDate' && member.probationarySkipped) return 'Skipped';
      return raw ? toDateLabel(raw) : '—';
    }
    if (def.type === 'boolean') {
      return raw ? 'Yes' : 'No';
    }
    if (def.type === 'percent') {
      return raw != null && raw !== '' ? `${raw}%` : '—';
    }
    if (raw == null || raw === '') return '—';
    return String(raw);
  }

  function getInitials(name) {
    return String(name || 'M').trim().split(/\s+/).slice(0, 2).map(p => p[0]).join('').toUpperCase() || 'M';
  }

  function memberAvatarHtml(member) {
    const photo = member.profilePhoto || member.photo || '';
    if (photo && (String(photo).startsWith('data:') || String(photo).startsWith('http') || String(photo).length > 100)) {
      const src = String(photo).startsWith('data:') ? photo : `data:image/jpeg;base64,${photo}`;
      return `<div class="mp-avatar has-photo"><img src="${safeText(src)}" alt="${safeText(member.fullName)}" /></div>`;
    }
    return `<div class="mp-avatar">${safeText(getInitials(member.fullName))}</div>`;
  }

  function stageBadgeClass(periodGroup) {
    return periodGroup === 'Membership Period' ? 'badge-green' :
      periodGroup === 'Probationary Period' ? 'badge-gold' : 'badge-blue';
  }

  // ---------------------------------------------------------------------------
  // Professional bordered tables (print document)
  // ---------------------------------------------------------------------------

  function generateMemberRecordTable(member, index) {
    const sections = {};
    FIELD_DEFINITIONS.forEach(def => {
      if (!sections[def.section]) sections[def.section] = [];
      sections[def.section].push(def);
    });

    const tablesHtml = SECTION_ORDER.map(sectionName => {
      const fields = sections[sectionName];
      if (!fields) return '';
      const rowsHtml = fields.map(def => {
        const value = formatFieldValue(member, def);
        return `<tr><th scope="row">${safeText(def.label)}</th><td>${safeText(value)}</td></tr>`;
      }).join('');

      return `<table class="mp-detail-table">
        <thead><tr><th colspan="2"><span class="mp-sec-no">${SECTION_NUMBERS[sectionName] || ''}</span>${safeText(sectionName)}</th></tr></thead>
        <tbody>${rowsHtml}</tbody>
      </table>`;
    }).join('');

    const quality = member.recordQuality != null ? `${member.recordQuality}%` : '—';

    return `<article class="mp-card">
      <header class="mp-card-header">
        <div class="mp-card-identity">
          ${memberAvatarHtml(member)}
          <div class="mp-card-title">
            <h2>${safeText(member.fullName || 'Unnamed Member')}</h2>
            <p>${safeText(member.membershipId || 'No Membership ID')} • ${safeText(member.studentNumber || 'No Student No.')} • ${safeText(member.orchestraSection || 'No Section')} • ${safeText(member.primaryInstrument || 'No Instrument')}</p>
            <div class="mp-badges">
              <span class="mp-badge ${stageBadgeClass(member.periodGroup)}">${safeText(member.periodGroup || '')}</span>
              <span class="mp-badge badge-gray">${safeText(member.memberStatus || 'No Status')}</span>
              <span class="mp-badge badge-gray">Quality: ${safeText(quality)}</span>
              <span class="mp-badge badge-gray">${safeText(member.organizationPosition || '')}${member.organizationRole ? ' • ' + safeText(member.organizationRole) : ''}</span>
            </div>
          </div>
        </div>
        <div class="mp-card-index">#${String(index + 1).padStart(3, '0')}</div>
      </header>
      <div class="mp-card-body">
        ${tablesHtml}
      </div>
    </article>`;
  }

  function generateSummaryTable(members, stage) {
    const rows = members.map((m, i) => `<tr>
      <td class="c-index">${i + 1}</td>
      <td><strong>${safeText(m.fullName)}</strong><small>${safeText(m.membershipId || '')} • ${safeText(m.studentNumber || '')}</small></td>
      <td>${safeText(m.orchestraSection || '—')}<small>${safeText(m.primaryInstrument || '')}</small></td>
      <td>${safeText(m.course || m.college || '—')}<small>${safeText(m.yearLevel || '')} ${safeText(m.section || '')}</small></td>
      <td>${safeText(m.organizationPosition || '—')}<small>${safeText(m.organizationRole || '')}</small></td>
      <td>${safeText(m.memberStatus || '—')}</td>
      <td class="c-index">${safeText(m.recordQuality != null ? m.recordQuality + '%' : '—')}</td>
    </tr>`).join('');

    return `<section class="mp-summary">
      <div class="mp-summary-head">
        <h3>Directory Summary • ${safeText(stage)}</h3>
        <span>${members.length} record${members.length === 1 ? '' : 's'} • ${PAPER_LABEL} Portrait</span>
      </div>
      <div class="mp-table-wrap">
        <table class="mp-table">
          <thead><tr><th>#</th><th>Member / IDs</th><th>Section / Instrument</th><th>Program / Year</th><th>Organization</th><th>Status</th><th>Quality</th></tr></thead>
          <tbody>${rows || '<tr><td colspan="7">No records to display.</td></tr>'}</tbody>
        </table>
      </div>
    </section>`;
  }

  function printCss() {
    return `
      @page { size: ${PAPER_WIDTH_IN}in ${PAPER_HEIGHT_IN}in; margin: 0; }
      * { box-sizing: border-box; }
      html, body { margin:0; padding:0; background:#fff; color:#17211d; font-family: "Inter", Arial, Helvetica, sans-serif; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      body { width: ${PAPER_WIDTH_IN}in; min-width: ${PAPER_WIDTH_IN}in; background:#fff; }

      /* Fixed header/footer repeating on each page (safe inch geometry) */
      .lso-print-header { position: fixed; top:0; left:0; right:0; height: ${inches(HEADER_HEIGHT_IN)}; background:#fff; z-index: 100; border-bottom: 1.2px solid #0b3d2e; overflow:hidden; }
      .lso-print-header img { width:100%; height:100%; object-fit: fill; display:block; }
      .lso-print-footer { position: fixed; bottom:0; left:0; right:0; height: ${inches(FOOTER_HEIGHT_IN)}; background:#fff; z-index:100; border-top: 0.8px solid #c7a547; overflow:hidden; }
      .lso-print-footer img { width:100%; height:100%; object-fit: fill; display:block; }

      .lso-print-content { margin: ${inches(MARGIN_TOP_IN)} ${inches(MARGIN_SIDE_IN)} ${inches(MARGIN_BOTTOM_IN)} ${inches(MARGIN_SIDE_IN)}; }

      /* Document heading */
      .mp-doc-head { text-align:center; padding: 6mm 5mm 5mm; margin: 0 0 5mm; border: 1px solid #0b3d2e; border-top: 3.5px solid #0b3d2e; border-bottom: 2px solid #c7a547; border-radius: 3mm; background: linear-gradient(180deg, #f7fbf9 0%, #ffffff 100%); break-inside: avoid; page-break-inside: avoid; }
      .mp-doc-head h1 { margin:0; font-size: 15px; color:#0b3d2e; letter-spacing: -0.01em; line-height:1.2; }
      .mp-doc-head .mp-subtitle { margin: 2mm 0 0; font-size: 10px; color:#135441; font-weight:700; letter-spacing:0.04em; text-transform:uppercase; }
      .mp-doc-head .mp-meta { margin: 2.5mm 0 0; display:flex; flex-wrap:wrap; justify-content:center; gap: 3mm; font-size:7.4px; color:#5a7169; }
      .mp-doc-head .mp-meta span { display:inline-flex; gap:1.2mm; }
      .mp-doc-head .mp-meta strong { color:#0b3d2e; }
      .mp-doc-head .mp-filters { margin-top: 3mm; padding: 2.5mm 3mm; border-radius: 2mm; background:#f2fcf7; border:1px solid #9db8ad; font-size:7px; color:#4c635a; text-align:left; line-height:1.5; }
      .mp-doc-head .mp-filters b { color:#0b3d2e; }
      .mp-doc-head .mp-note { margin-top:3mm; font-size:6.6px; color:#6c8079; line-height:1.45; }

      /* Professional bordered summary table */
      .mp-summary { margin: 0 0 6mm; border:1px solid #0b3d2e; border-radius: 2mm; overflow:hidden; background:#fff; break-inside: avoid; }
      .mp-summary-head { display:flex; justify-content:space-between; align-items:center; gap:3mm; padding: 3mm 4mm; background: linear-gradient(90deg, #0b3d2e 0%, #167055 100%); color:#fff; }
      .mp-summary-head h3 { margin:0; font-size:10.5px; letter-spacing:0.02em; }
      .mp-summary-head span { font-size:7px; background: rgba(255,255,255,0.18); padding: 1mm 2.5mm; border-radius:999px; white-space:nowrap; }
      .mp-table-wrap { overflow:hidden; }
      .mp-table { width:100%; border-collapse: collapse; font-size: 7.2px; }
      .mp-table th, .mp-table td { border: 0.5pt solid #9db8ad; }
      .mp-table thead th { background:#0b3d2e; color:#fff; font-size:6.6px; text-transform:uppercase; letter-spacing:0.05em; padding: 2.2mm 2mm; text-align:left; white-space:nowrap; }
      .mp-table tbody td { padding: 2mm 2mm; vertical-align:top; line-height:1.35; }
      .mp-table tbody td strong { color:#0b3d2e; font-size:7.4px; }
      .mp-table tbody td small { display:block; color:#6c8079; font-size:6.1px; margin-top:0.5mm; }
      .mp-table tbody tr:nth-child(even) td { background:#f4faf7; }
      .mp-table td.c-index { text-align:center; font-weight:800; color:#0b3d2e; }

      /* Member record cards with professional bordered detail tables */
      .mp-cards { display:grid; gap: 5mm; }
      .mp-card { border:1px solid #0b3d2e; border-radius: 2.5mm; overflow:hidden; background:#fff; break-inside: avoid; page-break-inside: avoid; }
      .mp-card-header { display:flex; justify-content:space-between; align-items:flex-start; gap:3mm; padding: 3.5mm 4mm; background: linear-gradient(135deg, #0b3d2e 0%, #135441 55%, #167055 100%); color:#fff; }
      .mp-card-identity { display:flex; gap:3mm; align-items:flex-start; min-width:0; flex:1; }
      .mp-avatar { width:12mm; height:12mm; border-radius: 2.5mm; background:#fff; color:#0b3d2e; display:grid; place-items:center; font-weight:900; font-size:4.5mm; flex:0 0 12mm; border: 0.6mm solid #c7a547; overflow:hidden; }
      .mp-avatar.has-photo { background:#fff; padding:0; }
      .mp-avatar img { width:100%; height:100%; object-fit:cover; display:block; }
      .mp-card-title { min-width:0; flex:1; }
      .mp-card-title h2 { margin:0; font-size:11px; line-height:1.25; color:#fff; overflow-wrap: anywhere; }
      .mp-card-title p { margin: 0.8mm 0 0; font-size:7px; color:#c9f5dc; line-height:1.35; overflow-wrap:anywhere; }
      .mp-badges { display:flex; flex-wrap:wrap; gap:1.2mm; margin-top:1.8mm; }
      .mp-badge { display:inline-flex; align-items:center; padding:0.7mm 2mm; border-radius:999px; font-size:6px; font-weight:800; letter-spacing:0.02em; line-height:1; border:0.25mm solid transparent; }
      .badge-green { background:#dff7e9; color:#0d6c49; border-color:#8eb9a4; }
      .badge-gold { background:#fff4cc; color:#7a5a00; border-color:#d4a017; }
      .badge-blue { background:#e3eefc; color:#1e4a8a; border-color:#8aa8d6; }
      .badge-gray { background:#edf1ef; color:#4b5c56; border-color:#b9c7c1; }
      .mp-card-index { flex:0 0 auto; font-size:9px; font-weight:900; color:#e5c35d; background: rgba(0,0,0,0.18); border:1px solid rgba(229,195,93,0.35); padding:1.5mm 2.5mm; border-radius:999px; letter-spacing:0.04em; }

      .mp-card-body { padding: 3.5mm 4mm; display:grid; gap:3mm; }
      .mp-detail-table { width:100%; border-collapse: collapse; font-size:7.1px; break-inside: avoid; page-break-inside: avoid; }
      .mp-detail-table th, .mp-detail-table td { border: 0.5pt solid #9db8ad; padding: 1.9mm 2.4mm; text-align:left; vertical-align:top; line-height:1.4; }
      .mp-detail-table thead th { background:#0b3d2e; color:#fff; font-size:7.6px; text-transform:uppercase; letter-spacing:0.05em; font-weight:800; }
      .mp-detail-table thead th .mp-sec-no { display:inline-grid; place-items:center; width:5mm; height:5mm; margin-right:2mm; border-radius:50%; background:#c7a547; color:#0b3d2e; font-size:3.8px; font-weight:900; vertical-align:middle; }
      .mp-detail-table tbody th { width: 38%; background:#f1f7f4; color:#33544a; font-size:6.4px; text-transform:uppercase; letter-spacing:0.05em; font-weight:800; }
      .mp-detail-table tbody td { color:#17211d; font-weight:600; overflow-wrap:anywhere; word-break:break-word; }
      .mp-detail-table tbody tr:nth-child(even) td { background:#fcfefd; }

      /* Signatory */
      .mp-signatory { display:grid; grid-template-columns: 1fr 1fr; gap:12mm; margin-top:8mm; padding-top:5mm; border-top:0.4mm solid #0b3d2e; break-inside: avoid; }
      .mp-signatory > div { text-align:center; }
      .mp-signatory .mp-sign-line { border-top:0.4mm solid #263b33; padding-top:2mm; margin-top:10mm; }
      .mp-signatory strong { display:block; font-size:8px; color:#0b3d2e; }
      .mp-signatory span { display:block; font-size:6px; color:#5a7169; text-transform:uppercase; letter-spacing:0.05em; margin-top:1mm; }

      /* Footer meta */
      .mp-print-meta { margin-top:5mm; text-align:center; font-size:6.2px; color:#8aa89b; line-height:1.5; }
      .mp-print-meta b { color:#0b3d2e; }

      @media print {
        body { background:#fff; }
        .no-print { display:none !important; }
      }
    `;
  }

  function generatePrintHtml(members, stage, options = {}) {
    const headerUrl = getOfficialAssetDataUri('lso-official-header.png');
    const footerUrl = getOfficialAssetDataUri('lso-official-footer.png');
    const today = todayISO();
    const account = currentAccount();
    const generatedBy = account?.displayName || account?.username || 'System';
    const dateLabel = toDateLabel(today);
    const scopeLabel = options.scopeLabel || `All Filtered • ${members.length} record${members.length === 1 ? '' : 's'}`;
    const docKind = options.docKind || 'Official Members Directory';
    const isSingle = members.length === 1 && options.single === true;

    const searchTerm = el('memberSearch')?.value || '';
    const statusFilter = el('statusFilter')?.value || 'All';
    const sectionFilter = el('sectionFilter')?.value || 'All';
    const positionFilter = el('positionFilter')?.value || 'All';

    const summaryHtml = generateSummaryTable(members, stage);
    const cardsHtml = members.map((m, i) => generateMemberRecordTable(m, i)).join('');

    const filterInfo = `
      <div class="mp-filters">
        <b>Print Scope:</b> ${safeText(scopeLabel)}<br>
        <b>Filters Applied:</b> Search: ${safeText(searchTerm || 'None')} • Status: ${safeText(statusFilter)} • Orchestra Section: ${safeText(sectionFilter)} • Position: ${safeText(positionFilter)}<br>
        <b>Coverage:</b> ${safeText(stage)} only • Sorted by Full Name (A-Z)<br>
        <b>Fields:</b> All information as indicated in System Management (Personal, Academic, Organization, Membership Timeline, Record Notes) including profile photo, quality score, and remarks.
      </div>
    `;

    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>LSO ${safeText(docKind)} • ${safeText(stage)} • ${safeText(dateLabel)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>${printCss()}</style>
</head>
<body>
<div class="lso-print-header"><img src="${safeText(headerUrl)}" alt="LSO Official Header" onerror="this.style.display='none'"></div>
<div class="lso-print-footer"><img src="${safeText(footerUrl)}" alt="LSO Official Footer" onerror="this.style.display='none'"></div>
<div class="lso-print-content">
  <header class="mp-doc-head">
    <h1>LASALLIAN SYMPHONY ORCHESTRA</h1>
    <div class="mp-subtitle">${safeText(docKind)} • ${safeText(stage)} • ${PAPER_LABEL} Portrait</div>
    <div class="mp-meta">
      <span><strong>Generated:</strong> ${safeText(dateLabel)}</span>
      <span><strong>By:</strong> ${safeText(generatedBy)}</span>
      <span><strong>Records:</strong> ${members.length}</span>
      <span><strong>Paper:</strong> ${PAPER_LABEL} Portrait</span>
    </div>
    ${filterInfo}
    <div class="mp-note">This document uses the official LSO header (${HEADER_HEIGHT_IN}in) and footer (${FOOTER_HEIGHT_IN}in). For professional output, enable <b>Background graphics</b> and set <b>Margins: None</b> in the browser print dialog. The system requests ${PAPER_WIDTH_IN}in x ${PAPER_HEIGHT_IN}in portrait portrait paper with safe content margins (${MARGIN_TOP_IN}in top / ${MARGIN_SIDE_IN}in sides / ${MARGIN_BOTTOM_IN}in bottom).</div>
  </header>

  ${summaryHtml}

  <section class="mp-cards">
    ${cardsHtml || `<div class="mp-summary"><div class="mp-summary-head"><h3>No records</h3><span>0</span></div><div style="padding:6mm; font-size:8px; color:#6c8079;">No members match the current ${safeText(stage)} selection.</div></div>`}
  </section>

  <section class="mp-signatory">
    <div><div class="mp-sign-line"><strong>${safeText(isSingle ? generatedBy : generatedBy)}</strong><span>Prepared By / Membership Officer</span></div></div>
    <div><div class="mp-sign-line"><strong></strong><span>Authorized Officer / President</span></div></div>
  </section>

  <div class="mp-print-meta">
    <b>Lasallian Symphony Orchestra</b> • ${safeText(docKind)} • ${safeText(stage)} • Generated ${safeText(dateLabel)} • ${members.length} record${members.length === 1 ? '' : 's'}<br>
    This is a system-generated document containing all member information as indicated in System Management. Keep confidential.<br>
    Paper: ${PAPER_LABEL} Portrait (${PAPER_WIDTH_IN}" x ${PAPER_HEIGHT_IN}") • Official Header &amp; Footer • LSO Database System
  </div>
</div>
<script>
  window.addEventListener('load', () => {
    setTimeout(() => {
      try { window.print(); } catch(e) {}
    }, 600);
  });
<\/script>
</body>
</html>`;
  }

  function openPrintWindow(html) {
    const popup = window.open('', '_blank', 'width=1150,height=900,scrollbars=yes');
    if (!popup) {
      window.LSOApp?.showToast?.('Please allow pop-ups to print the directory.', true);
      return false;
    }
    popup.document.open();
    popup.document.write(html);
    popup.document.close();
    try { popup.focus(); } catch {}
    return true;
  }

  function logPrintActivity(stage, count, scope) {
    try {
      window.LSOOperations?.logActivity?.('Printed members directory', 'Members', `${stage} • ${count} record${count === 1 ? '' : 's'} • ${scope} • ${PAPER_LABEL} Portrait • Official Header/Footer`);
    } catch {}
  }

  function confirmLargePrint(count) {
    if (count <= 40) return true;
    return window.confirm(`You are about to print ${count} members with full details (all system management fields) on ${PAPER_LABEL} portrait paper with official header/footer.\n\nThis will generate a professional multi-page document. Continue?`);
  }

  function printMembers(members, stage, scopeLabel) {
    if (!members.length) {
      window.LSOApp?.showToast?.('No members selected for printing.', true);
      return;
    }
    if (!confirmLargePrint(members.length)) return;
    try {
      const html = generatePrintHtml(members, stage, { scopeLabel });
      const opened = openPrintWindow(html);
      if (opened) {
        logPrintActivity(stage, members.length, scopeLabel);
        window.LSOApp?.showToast?.(`${stage} print prepared: ${members.length} member${members.length === 1 ? '' : 's'} (${scopeLabel}) on ${PAPER_LABEL}.`);
      }
    } catch (error) {
      console.error('[Members Directory Print] Failed', error);
      window.LSOApp?.showToast?.(error.message || 'Directory print could not be generated.', true);
    }
  }

  function printSingleMember(id) {
    const member = getMemberById(id);
    if (!member) {
      window.LSOApp?.showToast?.('Member record not found.', true);
      return;
    }
    const stage = member.periodGroup || getCurrentStage();
    try {
      const html = generatePrintHtml([member], stage, {
        scopeLabel: `Individual Record • ${member.fullName || 'Member'}`,
        docKind: 'Official Member Record',
        single: true
      });
      const opened = openPrintWindow(html);
      if (opened) {
        logPrintActivity(stage, 1, `Individual: ${member.fullName || member.membershipId || id}`);
        window.LSOApp?.showToast?.(`Official record print prepared for ${member.fullName || 'member'}.`);
      }
    } catch (error) {
      console.error('[Members Directory Print] Single print failed', error);
      window.LSOApp?.showToast?.(error.message || 'Member print could not be generated.', true);
    }
  }

  // ---------------------------------------------------------------------------
  // Directory table decoration: checkbox column + per-row print button
  // ---------------------------------------------------------------------------

  function directoryTable() {
    return document.querySelector('#membersView .members-directory-table');
  }

  function rowMemberId(row) {
    const actionBtn = row.querySelector('[data-action][data-id]');
    if (actionBtn) return String(actionBtn.getAttribute('data-id') || '');
    return '';
  }

  function ensurePrintColumn() {
    const table = directoryTable();
    if (!table) return;
    // Add colgroup entry once
    const colgroup = table.querySelector('colgroup');
    if (colgroup && !colgroup.querySelector('col.col-print-select')) {
      const col = document.createElement('col');
      col.className = 'col-print-select';
      colgroup.insertBefore(col, colgroup.firstChild);
    }
    // Add header checkbox once
    const headRow = table.querySelector('thead tr');
    if (headRow && !headRow.querySelector('th.mp-select-col')) {
      const th = document.createElement('th');
      th.className = 'mp-select-col';
      th.setAttribute('scope', 'col');
      th.innerHTML = `<input type="checkbox" id="mpSelectAll" class="mp-select-all" aria-label="Select all listed members for printing" title="Select all listed members">`;
      headRow.insertBefore(th, headRow.firstChild);
      const selectAll = th.querySelector('#mpSelectAll');
      selectAll.addEventListener('change', () => {
        const filtered = getFilteredMembersForPrint();
        if (selectAll.checked) {
          filtered.forEach(m => selectedIds.add(String(m.id)));
        } else {
          filtered.forEach(m => selectedIds.delete(String(m.id)));
        }
        syncRowCheckboxes();
        updatePrintButtonLabel();
      });
    }
  }

  function decorateRows() {
    if (decorating) return;
    decorating = true;
    try {
      ensurePrintColumn();
      const tbody = el('membersTableBody');
      if (!tbody) return;
      const rows = tbody.querySelectorAll('tr');
      rows.forEach(row => {
        const id = rowMemberId(row);
        if (!id) return;
        // Checkbox cell (prepend once)
        if (!row.querySelector('td.mp-select-cell')) {
          const td = document.createElement('td');
          td.className = 'mp-select-cell';
          const label = row.querySelector('.member-name')?.textContent?.trim() || 'member';
          td.innerHTML = `<input type="checkbox" class="mp-row-select" data-id="${safeText(id)}" aria-label="Select ${safeText(label)} for printing">`;
          row.insertBefore(td, row.firstChild);
        }
        // Per-row print button (append once into actions)
        const actions = row.querySelector('.member-row-actions');
        if (actions && !actions.querySelector('[data-print-row]')) {
          const btn = document.createElement('button');
          btn.type = 'button';
          btn.className = 'table-action print-row-action';
          btn.setAttribute('data-print-row', id);
          const label = row.querySelector('.member-name')?.textContent?.trim() || 'member';
          btn.setAttribute('aria-label', `Print official record of ${label}`);
          btn.title = 'Print individual record (Portrait, Official Header/Footer)';
          btn.innerHTML = `<svg aria-hidden="true" viewBox="0 0 24 24"><path d="M6 9V3h12v6"></path><path d="M6 18H4a2 2 0 0 1-2-2v-5a2 2 0 0 1 2-2h16a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2h-2"></path><rect x="6" y="14" width="12" height="7"></rect></svg>`;
          actions.appendChild(btn);
        }
      });
      syncRowCheckboxes();
    } finally {
      decorating = false;
    }
  }

  function syncRowCheckboxes() {
    const tbody = el('membersTableBody');
    if (!tbody) return;
    tbody.querySelectorAll('.mp-row-select').forEach(box => {
      const id = String(box.getAttribute('data-id') || '');
      box.checked = selectedIds.has(id);
      const row = box.closest('tr');
      if (row) row.classList.toggle('mp-row-selected', box.checked);
    });
    const selectAll = el('mpSelectAll');
    if (selectAll) {
      const filtered = getFilteredMembersForPrint();
      const checkedCount = filtered.filter(m => selectedIds.has(String(m.id))).length;
      selectAll.checked = filtered.length > 0 && checkedCount === filtered.length;
      selectAll.indeterminate = checkedCount > 0 && checkedCount < filtered.length;
    }
  }

  // ---------------------------------------------------------------------------
  // Selection modal
  // ---------------------------------------------------------------------------

  function ensureSelectModal() {
    if (el('mpSelectModal')) return el('mpSelectModal');
    const overlay = document.createElement('div');
    overlay.id = 'mpSelectModal';
    overlay.className = 'mp-select-modal hidden';
    overlay.setAttribute('role', 'dialog');
    overlay.setAttribute('aria-modal', 'true');
    overlay.setAttribute('aria-labelledby', 'mpSelectTitle');
    overlay.innerHTML = `
      <div class="mp-select-card">
        <div class="mp-select-header">
          <div>
            <p class="eyebrow">Official Print Selection</p>
            <h2 id="mpSelectTitle">Select Members to Print</h2>
            <p class="mp-select-subtitle" id="mpSelectSubtitle">Choose exactly which members appear in the official document.</p>
          </div>
          <button type="button" class="icon-button" id="mpSelectClose" aria-label="Close selection">×</button>
        </div>
        <div class="mp-select-toolbar">
          <div class="mp-select-counts"><span id="mpSelectCount">0 selected</span><span aria-hidden="true">•</span><span id="mpSelectTotal">0 listed</span></div>
          <div class="mp-select-tools">
            <button type="button" class="button button-secondary mp-select-tool" id="mpSelectAllBtn">Select All</button>
            <button type="button" class="button button-secondary mp-select-tool" id="mpSelectClearBtn">Clear</button>
          </div>
        </div>
        <div class="mp-select-list" id="mpSelectList"></div>
        <div class="mp-select-footer">
          <button type="button" class="button button-secondary" id="mpSelectCancel">Cancel</button>
          <button type="button" class="button button-secondary" id="mpPrintAllFiltered">Print All Listed</button>
          <button type="button" class="button button-primary" id="mpPrintSelected">Print Selected</button>
        </div>
      </div>`;
    document.body.appendChild(overlay);

    el('mpSelectClose').addEventListener('click', closeSelectModal);
    el('mpSelectCancel').addEventListener('click', closeSelectModal);
    overlay.addEventListener('click', (event) => { if (event.target === overlay) closeSelectModal(); });
    document.addEventListener('keydown', (event) => {
      if (event.key === 'Escape' && !overlay.classList.contains('hidden')) closeSelectModal();
    });
    el('mpSelectAllBtn').addEventListener('click', () => {
      getFilteredMembersForPrint().forEach(m => selectedIds.add(String(m.id)));
      renderSelectList();
      syncRowCheckboxes();
      updatePrintButtonLabel();
    });
    el('mpSelectClearBtn').addEventListener('click', () => {
      getFilteredMembersForPrint().forEach(m => selectedIds.delete(String(m.id)));
      renderSelectList();
      syncRowCheckboxes();
      updatePrintButtonLabel();
    });
    el('mpPrintAllFiltered').addEventListener('click', () => {
      const stage = getCurrentStage();
      const members = getFilteredMembersForPrint();
      closeSelectModal();
      printMembers(members, stage, `All Listed • ${members.length} record${members.length === 1 ? '' : 's'}`);
    });
    el('mpPrintSelected').addEventListener('click', () => {
      const stage = getCurrentStage();
      const filtered = getFilteredMembersForPrint();
      const members = filtered.filter(m => selectedIds.has(String(m.id)));
      if (!members.length) {
        window.LSOApp?.showToast?.('Select at least one member, or choose Print All Listed.', true);
        return;
      }
      closeSelectModal();
      const scope = members.length === filtered.length
        ? `All Listed • ${members.length} record${members.length === 1 ? '' : 's'}`
        : `Selected Members • ${members.length} of ${filtered.length} listed`;
      printMembers(members, stage, scope);
    });
    return overlay;
  }

  function renderSelectList() {
    const list = el('mpSelectList');
    if (!list) return;
    const stage = getCurrentStage();
    const members = getFilteredMembersForPrint();
    const checkedCount = members.filter(m => selectedIds.has(String(m.id))).length;

    el('mpSelectSubtitle').textContent = `${stage} • ${members.length} member${members.length === 1 ? '' : 's'} listed with current filters • ${PAPER_LABEL} Portrait`;
    el('mpSelectCount').textContent = `${checkedCount} selected`;
    el('mpSelectTotal').textContent = `${members.length} listed`;
    const printSelectedBtn = el('mpPrintSelected');
    printSelectedBtn.disabled = checkedCount === 0;
    printSelectedBtn.textContent = checkedCount > 0 ? `Print Selected (${checkedCount})` : 'Print Selected';
    el('mpPrintAllFiltered').textContent = `Print All Listed (${members.length})`;

    if (!members.length) {
      list.innerHTML = `<div class="mp-select-empty"><div class="empty-icon">♫</div><h4>No members listed</h4><p>Adjust the directory filters first.</p></div>`;
      return;
    }

    list.innerHTML = members.map(m => {
      const id = String(m.id);
      const checked = selectedIds.has(id) ? ' checked' : '';
      return `<label class="mp-select-row${selectedIds.has(id) ? ' is-checked' : ''}">
        <input type="checkbox" class="mp-modal-select" data-id="${safeText(id)}"${checked}>
        <span class="mp-select-avatar">${safeText(getInitials(m.fullName))}</span>
        <span class="mp-select-identity">
          <strong>${safeText(m.fullName || 'Unnamed Member')}</strong>
          <small>${safeText(m.membershipId || 'No ID')} • ${safeText(m.studentNumber || 'No Student No.')} • ${safeText(m.orchestraSection || 'No Section')} • ${safeText(m.primaryInstrument || 'No Instrument')}</small>
        </span>
        <span class="mp-badge ${stageBadgeClass(m.periodGroup)}">${safeText(m.memberStatus || '')}</span>
      </label>`;
    }).join('');

    list.querySelectorAll('.mp-modal-select').forEach(box => {
      box.addEventListener('change', () => {
        const id = String(box.getAttribute('data-id') || '');
        if (box.checked) selectedIds.add(id);
        else selectedIds.delete(id);
        box.closest('.mp-select-row')?.classList.toggle('is-checked', box.checked);
        renderSelectListCountsOnly();
        syncRowCheckboxes();
        updatePrintButtonLabel();
      });
    });
  }

  function renderSelectListCountsOnly() {
    const members = getFilteredMembersForPrint();
    const checkedCount = members.filter(m => selectedIds.has(String(m.id))).length;
    el('mpSelectCount').textContent = `${checkedCount} selected`;
    const printSelectedBtn = el('mpPrintSelected');
    printSelectedBtn.disabled = checkedCount === 0;
    printSelectedBtn.textContent = checkedCount > 0 ? `Print Selected (${checkedCount})` : 'Print Selected';
  }

  function openSelectModal() {
    const stage = getCurrentStage();
    const members = getFilteredMembersForPrint();
    if (!members.length) {
      window.LSOApp?.showToast?.(`No ${stage} members match the current filters.`, true);
      return;
    }
    ensureSelectModal();
    renderSelectList();
    el('mpSelectModal').classList.remove('hidden');
    document.body.style.overflow = 'hidden';
    setTimeout(() => el('mpSelectClose')?.focus(), 60);
  }

  function closeSelectModal() {
    el('mpSelectModal')?.classList.add('hidden');
    document.body.style.overflow = '';
  }

  function handlePrint() {
    openSelectModal();
  }

  // ---------------------------------------------------------------------------
  // Print button label + wiring
  // ---------------------------------------------------------------------------

  function updatePrintButtonLabel() {
    const btn = el('printMembersDirectory');
    if (!btn) return;
    const stage = getCurrentStage();
    const shortLabel = stage.replace(' Period', '');
    const stageSpan = btn.querySelector('.print-stage-label');
    if (stageSpan) stageSpan.textContent = shortLabel;

    let countBadge = btn.querySelector('.print-selected-count');
    const selectedCount = getSelectedFilteredMembers().length;
    if (selectedCount > 0) {
      if (!countBadge) {
        countBadge = document.createElement('span');
        countBadge.className = 'print-selected-count';
        btn.appendChild(countBadge);
      }
      countBadge.textContent = `${selectedCount} selected`;
      countBadge.classList.remove('hidden');
    } else if (countBadge) {
      countBadge.classList.add('hidden');
    }

    const filtered = getFilteredMembersForPrint();
    btn.disabled = filtered.length === 0;
    btn.title = filtered.length === 0
      ? `No ${stage} members match current filters`
      : `Choose members to print from ${stage} (${PAPER_LABEL} Portrait, Official Header/Footer)`;
    if (selectedCount > 0) btn.title += ` • ${selectedCount} selected`;
  }

  function pruneSelectionToStage() {
    // A stage switch is a fresh selection context; keep the UI predictable.
    const stage = getCurrentStage();
    if (stage !== activeStage) {
      activeStage = stage;
      selectedIds.clear();
      closeSelectModal();
    }
    updatePrintButtonLabel();
  }

  function wireEvents() {
    const btn = el('printMembersDirectory');
    if (!btn) return;

    btn.addEventListener('click', handlePrint);

    // Update label when stage changes or filters change
    ['memberListMode', 'probationaryTab', 'traineeTab'].forEach(id => {
      el(id)?.addEventListener('click', () => setTimeout(pruneSelectionToStage, 80));
    });
    ['memberSearch', 'statusFilter', 'sectionFilter', 'positionFilter'].forEach(id => {
      const input = el(id);
      if (!input) return;
      const evt = input.tagName === 'SELECT' ? 'change' : 'input';
      input.addEventListener(evt, () => setTimeout(updatePrintButtonLabel, 120));
    });

    // Row checkbox toggles + per-row print (delegated; survives re-renders)
    const tbody = el('membersTableBody');
    if (tbody && !tbody.dataset.mpPrintWired) {
      tbody.dataset.mpPrintWired = 'true';
      tbody.addEventListener('change', (event) => {
        const box = event.target.closest('.mp-row-select');
        if (!box) return;
        const id = String(box.getAttribute('data-id') || '');
        if (!id) return;
        if (box.checked) selectedIds.add(id);
        else selectedIds.delete(id);
        box.closest('tr')?.classList.toggle('mp-row-selected', box.checked);
        syncRowCheckboxes();
        updatePrintButtonLabel();
      });
      tbody.addEventListener('click', (event) => {
        const printBtn = event.target.closest('[data-print-row]');
        if (!printBtn) return;
        event.stopPropagation();
        printSingleMember(printBtn.getAttribute('data-print-row'));
      });
      // Re-decorate whenever the directory re-renders its rows
      if (window.MutationObserver) {
        const observer = new MutationObserver(() => {
          decorateRows();
          updatePrintButtonLabel();
        });
        observer.observe(tbody, { childList: true });
      }
    }

    // Also listen to global member changes
    ['lso:members-changed', 'lso:cloud-state-changed'].forEach(name => {
      window.addEventListener(name, () => setTimeout(() => {
        // Drop selections for members that no longer exist
        const known = new Set(getMembers().map(m => String(m.id)));
        [...selectedIds].forEach(id => { if (!known.has(id)) selectedIds.delete(id); });
        decorateRows();
        updatePrintButtonLabel();
      }, 200));
    });

    // Initial decoration + label
    activeStage = getCurrentStage();
    setTimeout(() => { decorateRows(); updatePrintButtonLabel(); }, 400);
  }

  function initialize() {
    if (!el('membersView')) return;
    wireEvents();
    // Expose for debugging / external calls
    window.LSOMembersDirectoryPrint = {
      print: handlePrint,
      printSingle: printSingleMember,
      openSelection: openSelectModal,
      getCurrentStage,
      getFilteredMembers: getFilteredMembersForPrint,
      getSelectedMembers: getSelectedFilteredMembers,
      clearSelection: () => { selectedIds.clear(); syncRowCheckboxes(); updatePrintButtonLabel(); },
      paper: {
        widthIn: PAPER_WIDTH_IN,
        heightIn: PAPER_HEIGHT_IN,
        headerIn: HEADER_HEIGHT_IN,
        footerIn: FOOTER_HEIGHT_IN,
        marginTopIn: MARGIN_TOP_IN,
        marginSideIn: MARGIN_SIDE_IN,
        marginBottomIn: MARGIN_BOTTOM_IN
      },
      generateHtml: (stageOverride, membersOverride, scopeLabel) => {
        const stage = stageOverride || getCurrentStage();
        const members = membersOverride || getFilteredMembersForPrint();
        return generatePrintHtml(members, stage, { scopeLabel });
      }
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize, { once: true });
  } else {
    initialize();
  }
})();
