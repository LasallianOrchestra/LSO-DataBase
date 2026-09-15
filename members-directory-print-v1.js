/**
 * Members Directory Print v1 - Official LSO Short Bond Print
 * ----------------------------------------------------------------
 * Prints all members' information for the active directory stage
 * (Membership Period, Probationary Period, Trainee Period) as indicated
 * in system management, using official LSO header and footer,
 * short bond paper size (8.5" x 11" / Letter).
 *
 * Professional layout:
 * - Official header/footer on every page (fixed repeat)
 * - Short bond @page size
 * - Each member card includes all system management fields
 * - Profile photo, personal, academic, organization, timeline, remarks
 * - Summary table at start, paginated detailed cards
 * - Respects current filters and active tab
 *
 * Dependencies: LSOBrand (optional), LSO_OFFICIAL_PDF_ASSETS (optional), LSOApp.getMembers()
 */

(() => {
  'use strict';

  const SHORT_BOND_WIDTH = '8.5in';
  const SHORT_BOND_HEIGHT = '11in';
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

  function el(id) { return document.getElementById(id); }

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

  function toShortDate(value) {
    if (!value) return '';
    const d = new Date(`${value}T00:00:00`);
    if (Number.isNaN(d.getTime())) return String(value);
    try {
      return new Intl.DateTimeFormat('en-PH', { year: '2-digit', month: 'short', day: '2-digit' }).format(d);
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

  function getOfficialAssetDataUri(name) {
    try {
      const assets = window.LSO_OFFICIAL_PDF_ASSETS || {};
      const raw = assets[name];
      if (raw) {
        const trimmed = String(raw).trim();
        if (trimmed.startsWith('data:')) return trimmed;
        // Detect mime by extension
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
      // Assume data URI or base64
      const src = String(photo).startsWith('data:') ? photo : `data:image/jpeg;base64,${photo}`;
      return `<div class="mp-avatar has-photo"><img src="${safeText(src)}" alt="${safeText(member.fullName)}" /></div>`;
    }
    return `<div class="mp-avatar">${safeText(getInitials(member.fullName))}</div>`;
  }

  function generateMemberCard(member, index) {
    // Group fields by section
    const sections = {};
    FIELD_DEFINITIONS.forEach(def => {
      if (!sections[def.section]) sections[def.section] = [];
      sections[def.section].push(def);
    });

    const sectionOrder = ['Personal Information', 'Academic Information', 'Organization Information', 'Membership Timeline', 'Record Notes'];
    const sectionIcons = {
      'Personal Information': '01',
      'Academic Information': '02',
      'Organization Information': '03',
      'Membership Timeline': '04',
      'Record Notes': '05'
    };

    const sectionsHtml = sectionOrder.map(sectionName => {
      const fields = sections[sectionName];
      if (!fields) return '';
      const fieldsHtml = fields.map(def => {
        const value = formatFieldValue(member, def);
        const fullClass = def.full ? ' full' : '';
        return `<div class="mp-field${fullClass}"><span>${safeText(def.label)}</span><strong>${safeText(value)}</strong></div>`;
      }).join('');

      return `<div class="mp-section">
        <div class="mp-section-head"><span>${sectionIcons[sectionName] || ''}</span><h4>${safeText(sectionName)}</h4></div>
        <div class="mp-field-grid">${fieldsHtml}</div>
      </div>`;
    }).join('');

    const quality = member.recordQuality != null ? `${member.recordQuality}%` : '—';
    const stageBadgeClass = member.periodGroup === 'Membership Period' ? 'badge-green' :
      member.periodGroup === 'Probationary Period' ? 'badge-gold' : 'badge-blue';

    return `<article class="mp-card">
      <header class="mp-card-header">
        <div class="mp-card-identity">
          ${memberAvatarHtml(member)}
          <div class="mp-card-title">
            <h2>${safeText(member.fullName || 'Unnamed Member')}</h2>
            <p>${safeText(member.membershipId || 'No Membership ID')} • ${safeText(member.studentNumber || 'No Student No.')} • ${safeText(member.orchestraSection || 'No Section')} • ${safeText(member.primaryInstrument || 'No Instrument')}</p>
            <div class="mp-badges">
              <span class="mp-badge ${stageBadgeClass}">${safeText(member.periodGroup || '')}</span>
              <span class="mp-badge badge-gray">${safeText(member.memberStatus || 'No Status')}</span>
              <span class="mp-badge badge-gray">Quality: ${safeText(quality)}</span>
              <span class="mp-badge badge-gray">${safeText(member.organizationPosition || '')}${member.organizationRole ? ' • ' + safeText(member.organizationRole) : ''}</span>
            </div>
          </div>
        </div>
        <div class="mp-card-index">#${String(index + 1).padStart(3, '0')}</div>
      </header>
      <div class="mp-card-body">
        ${sectionsHtml}
      </div>
    </article>`;
  }

  function generateSummaryTable(members, stage) {
    const rows = members.map((m, i) => `<tr>
      <td>${i + 1}</td>
      <td><strong>${safeText(m.fullName)}</strong><br><small>${safeText(m.membershipId || '')} • ${safeText(m.studentNumber || '')}</small></td>
      <td>${safeText(m.orchestraSection || '—')}<br><small>${safeText(m.primaryInstrument || '')}</small></td>
      <td>${safeText(m.course || m.college || '—')}<br><small>${safeText(m.yearLevel || '')} ${safeText(m.section || '')}</small></td>
      <td>${safeText(m.organizationPosition || '—')}<br><small>${safeText(m.organizationRole || '')}</small></td>
      <td>${safeText(m.memberStatus || '—')}</td>
      <td>${safeText(m.recordQuality != null ? m.recordQuality + '%' : '—')}</td>
    </tr>`).join('');

    return `<section class="mp-summary">
      <div class="mp-summary-head">
        <h3>Directory Summary • ${safeText(stage)}</h3>
        <span>${members.length} record${members.length === 1 ? '' : 's'} • Short Bond (8.5" x 11")</span>
      </div>
      <div class="mp-table-wrap">
        <table class="mp-table">
          <thead><tr><th>#</th><th>Member / IDs</th><th>Section / Instrument</th><th>Program / Year</th><th>Organization</th><th>Status</th><th>Quality</th></tr></thead>
          <tbody>${rows || '<tr><td colspan=\"7\">No records to display.</td></tr>'}</tbody>
        </table>
      </div>
    </section>`;
  }

  function generatePrintHtml(members, stage) {
    const headerUrl = getOfficialAssetDataUri('lso-official-header.png');
    const footerUrl = getOfficialAssetDataUri('lso-official-footer.png');
    const today = todayISO();
    const account = currentAccount();
    const generatedBy = account?.displayName || account?.username || 'System';
    const dateLabel = toDateLabel(today);

    const searchTerm = el('memberSearch')?.value || '';
    const statusFilter = el('statusFilter')?.value || 'All';
    const sectionFilter = el('sectionFilter')?.value || 'All';
    const positionFilter = el('positionFilter')?.value || 'All';

    const summaryHtml = generateSummaryTable(members, stage);
    const cardsHtml = members.map((m, i) => generateMemberCard(m, i)).join('');

    // Professional CSS for short bond paper
    const css = `
      @page { size: ${SHORT_BOND_WIDTH} ${SHORT_BOND_HEIGHT}; margin: 0; }
      * { box-sizing: border-box; }
      html, body { margin:0; padding:0; background:#fff; color:#17211d; font-family: "Inter", Arial, Helvetica, sans-serif; -webkit-print-color-adjust: exact; print-color-adjust: exact; }
      body { width: ${SHORT_BOND_WIDTH}; min-width: ${SHORT_BOND_WIDTH}; background:#fff; }
      
      /* Fixed header/footer repeating on each page */
      .lso-print-header { position: fixed; top:0; left:0; right:0; height: 0.92in; background:#fff; z-index: 100; border-bottom: 1.2px solid #0b3d2e; overflow:hidden; }
      .lso-print-header img { width:100%; height:100%; object-fit: fill; display:block; }
      .lso-print-footer { position: fixed; bottom:0; left:0; right:0; height: 0.62in; background:#fff; z-index:100; border-top: 0.8px solid #c7a547; overflow:hidden; }
      .lso-print-footer img { width:100%; height:100%; object-fit: fill; display:block; }
      
      .lso-print-content { margin: 1.05in 0.52in 0.78in 0.52in; }
      
      /* Document heading */
      .mp-doc-head { text-align:center; padding: 6mm 5mm 5mm; margin: 0 0 5mm; border: 1px solid #d7e7df; border-top: 3.5px solid #0b3d2e; border-bottom: 2px solid #c7a547; border-radius: 3mm; background: linear-gradient(180deg, #f7fbf9 0%, #ffffff 100%); break-inside: avoid; page-break-inside: avoid; }
      .mp-doc-head h1 { margin:0; font-size: 14.5px; color:#0b3d2e; letter-spacing: -0.01em; line-height:1.2; }
      .mp-doc-head .mp-subtitle { margin: 2mm 0 0; font-size: 9.5px; color:#135441; font-weight:700; letter-spacing:0.04em; text-transform:uppercase; }
      .mp-doc-head .mp-meta { margin: 2.5mm 0 0; display:flex; flex-wrap:wrap; justify-content:center; gap: 3mm; font-size:7.2px; color:#5a7169; }
      .mp-doc-head .mp-meta span { display:inline-flex; gap:1.2mm; }
      .mp-doc-head .mp-meta strong { color:#0b3d2e; }
      .mp-doc-head .mp-filters { margin-top: 3mm; padding: 2.5mm 3mm; border-radius: 2mm; background:#f2fcf7; border:1px dashed #cfe3da; font-size:6.8px; color:#4c635a; text-align:left; line-height:1.5; }
      .mp-doc-head .mp-filters b { color:#0b3d2e; }
      .mp-doc-head .mp-note { margin-top:3mm; font-size:6.5px; color:#6c8079; line-height:1.45; }
      
      /* Summary table */
      .mp-summary { margin: 0 0 6mm; border:1px solid #d7e7df; border-radius: 3mm; overflow:hidden; background:#fff; break-inside: avoid; }
      .mp-summary-head { display:flex; justify-content:space-between; align-items:center; gap:3mm; padding: 3mm 4mm; background: linear-gradient(90deg, #0b3d2e 0%, #167055 100%); color:#fff; }
      .mp-summary-head h3 { margin:0; font-size:10px; letter-spacing:0.02em; }
      .mp-summary-head span { font-size:7px; background: rgba(255,255,255,0.18); padding: 1mm 2.5mm; border-radius:999px; }
      .mp-table-wrap { overflow:hidden; }
      .mp-table { width:100%; border-collapse: collapse; font-size: 7px; }
      .mp-table th { background:#f4faf7; color:#3f5a52; font-size:6.5px; text-transform:uppercase; letter-spacing:0.06em; padding: 2mm 2mm; text-align:left; border-bottom:1px solid #d7e7df; white-space:nowrap; }
      .mp-table td { padding: 2mm 2mm; border-bottom:1px solid #e8f0ec; vertical-align:top; line-height:1.35; }
      .mp-table td strong { color:#0b3d2e; font-size:7.2px; }
      .mp-table td small { display:block; color:#6c8079; font-size:6px; margin-top:0.5mm; }
      .mp-table tr:nth-child(even) td { background:#fcfefd; }
      
      /* Member cards */
      .mp-cards { display:grid; gap: 5mm; }
      .mp-card { border:1px solid #cbdcd5; border-radius: 3mm; overflow:hidden; background:#fff; break-inside: avoid; page-break-inside: avoid; box-shadow: 0 1mm 3mm rgba(11,61,46,0.06); }
      .mp-card-header { display:flex; justify-content:space-between; align-items:flex-start; gap:3mm; padding: 3.5mm 4mm; background: linear-gradient(135deg, #0b3d2e 0%, #135441 55%, #167055 100%); color:#fff; }
      .mp-card-identity { display:flex; gap:3mm; align-items:flex-start; min-width:0; flex:1; }
      .mp-avatar { width:12mm; height:12mm; border-radius: 2.5mm; background:#fff; color:#0b3d2e; display:grid; place-items:center; font-weight:900; font-size:4.5mm; flex:0 0 12mm; border: 0.6mm solid #c7a547; overflow:hidden; box-shadow: 0 0.5mm 2mm rgba(0,0,0,0.12); }
      .mp-avatar.has-photo { background:#fff; padding:0; }
      .mp-avatar img { width:100%; height:100%; object-fit:cover; display:block; }
      .mp-card-title { min-width:0; flex:1; }
      .mp-card-title h2 { margin:0; font-size:10.5px; line-height:1.25; color:#fff; overflow-wrap: anywhere; }
      .mp-card-title p { margin: 0.8mm 0 0; font-size:6.8px; color:#c9f5dc; line-height:1.35; overflow-wrap:anywhere; }
      .mp-badges { display:flex; flex-wrap:wrap; gap:1.2mm; margin-top:1.8mm; }
      .mp-badge { display:inline-flex; align-items:center; padding:0.7mm 2mm; border-radius:999px; font-size:5.8px; font-weight:800; letter-spacing:0.02em; line-height:1; border:0.25mm solid transparent; }
      .badge-green { background:#dff7e9; color:#0d6c49; border-color:#8eb9a4; }
      .badge-gold { background:#fff4cc; color:#7a5a00; border-color:#d4a017; }
      .badge-blue { background:#e3eefc; color:#1e4a8a; border-color:#8aa8d6; }
      .badge-gray { background: rgba(255,255,255,0.18); color:#e6f5ef; border-color: rgba(255,255,255,0.25); }
      .mp-card .mp-badge.badge-gray { background:#edf1ef; color:#4b5c56; border-color:#b9c7c1; }
      .mp-card-index { flex:0 0 auto; font-size:9px; font-weight:900; color:#e5c35d; background: rgba(0,0,0,0.18); border:1px solid rgba(229,195,93,0.35); padding:1.5mm 2.5mm; border-radius:999px; letter-spacing:0.04em; }
      
      .mp-card-body { padding: 3.5mm 4mm; }
      .mp-section { margin: 0 0 3.5mm; }
      .mp-section:last-child { margin-bottom:0; }
      .mp-section-head { display:flex; align-items:center; gap:2mm; margin:0 0 2mm; padding-bottom:1.2mm; border-bottom:0.6mm solid #e5c35d; }
      .mp-section-head span { width:5mm; height:5mm; border-radius:50%; background:#0b3d2e; color:#fff; display:grid; place-items:center; font-size:3.8px; font-weight:900; flex:0 0 5mm; }
      .mp-section-head h4 { margin:0; font-size:7.8px; color:#0b3d2e; text-transform:uppercase; letter-spacing:0.05em; font-weight:800; }
      .mp-field-grid { display:grid; grid-template-columns: 1fr 1fr; gap:1.8mm; }
      .mp-field { border:0.25mm solid #d8e6df; border-radius:1.2mm; padding:1.8mm 2.2mm; background:#f9fbf9; min-height:8.5mm; display:grid; align-content:start; }
      .mp-field.full { grid-column:1 / -1; }
      .mp-field span { display:block; font-size:5px; text-transform:uppercase; letter-spacing:0.07em; color:#5a7169; font-weight:800; margin-bottom:0.8mm; line-height:1.2; }
      .mp-field strong { display:block; font-size:7px; color:#17211d; line-height:1.35; font-weight:600; overflow-wrap: anywhere; word-break: break-word; }
      .mp-field.full strong { white-space: pre-wrap; }
      
      /* Signatory */
      .mp-signatory { display:grid; grid-template-columns: 1fr 1fr; gap:12mm; margin-top:8mm; padding-top:5mm; border-top:0.4mm solid #d7e7df; break-inside: avoid; }
      .mp-signatory > div { text-align:center; }
      .mp-signatory .mp-sign-line { border-top:0.4mm solid #263b33; padding-top:2mm; margin-top:10mm; }
      .mp-signatory strong { display:block; font-size:8px; color:#0b3d2e; }
      .mp-signatory span { display:block; font-size:6px; color:#5a7169; text-transform:uppercase; letter-spacing:0.05em; margin-top:1mm; }
      
      /* Footer meta */
      .mp-print-meta { margin-top:5mm; text-align:center; font-size:6px; color:#8aa89b; line-height:1.5; }
      .mp-print-meta b { color:#0b3d2e; }
      
      /* Page breaks */
      .mp-card { break-inside: avoid; }
      .mp-summary { break-after: auto; }
      
      /* Utility */
      .text-center { text-align:center; }
      .mt-4 { margin-top:4mm; }
      
      @media print {
        body { background:#fff; }
        .no-print { display:none !important; }
        .mp-card { box-shadow:none; }
      }
    `;

    const filterInfo = `
      <div class="mp-filters">
        <b>Filters Applied:</b> Search: ${safeText(searchTerm || 'None')} • Status: ${safeText(statusFilter)} • Orchestra Section: ${safeText(sectionFilter)} • Position: ${safeText(positionFilter)}<br>
        <b>Scope:</b> ${safeText(stage)} only • ${members.length} member${members.length === 1 ? '' : 's'} matched • Sorted by Full Name (A-Z)<br>
        <b>Fields:</b> All information as indicated in System Management (Personal, Academic, Organization, Membership Timeline, Record Notes) including profile photo, quality score, and remarks.
      </div>
    `;

    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>LSO Official Directory • ${safeText(stage)} • ${safeText(dateLabel)}</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>${css}</style>
</head>
<body>
<div class="lso-print-header"><img src="${safeText(headerUrl)}" alt="LSO Official Header" onerror="this.style.display='none'"></div>
<div class="lso-print-footer"><img src="${safeText(footerUrl)}" alt="LSO Official Footer" onerror="this.style.display='none'"></div>
<div class="lso-print-content">
  <header class="mp-doc-head">
    <h1>LASALLIAN SYMPHONY ORCHESTRA</h1>
    <div class="mp-subtitle">Official Members Directory • ${safeText(stage)} • Short Bond (8.5" x 11")</div>
    <div class="mp-meta">
      <span><strong>Generated:</strong> ${safeText(dateLabel)}</span>
      <span><strong>By:</strong> ${safeText(generatedBy)}</span>
      <span><strong>Records:</strong> ${members.length}</span>
      <span><strong>Paper:</strong> Short Bond Letter</span>
    </div>
    ${filterInfo}
    <div class="mp-note">This document uses the official LSO header and footer. For borderless professional output, enable <b>Background graphics</b> and set <b>Margins: None</b> in the browser print dialog. The system requests ${SHORT_BOND_WIDTH} x ${SHORT_BOND_HEIGHT} short bond paper.</div>
  </header>

  ${summaryHtml}

  <section class="mp-cards">
    ${cardsHtml || '<div class="mp-summary"><div class="mp-summary-head"><h3>No records</h3><span>0</span></div><div style="padding:6mm; font-size:8px; color:#6c8079;">No members match the current ${safeText(stage)} filters.</div></div>'}
  </section>

  <section class="mp-signatory">
    <div><div class="mp-sign-line"><strong>${safeText(generatedBy)}</strong><span>Prepared By / Membership Officer</span></div></div>
    <div><div class="mp-sign-line"><strong></strong><span>Authorized Officer / President</span></div></div>
  </section>

  <div class="mp-print-meta">
    <b>Lasallian Symphony Orchestra</b> • Official Members Directory • ${safeText(stage)} • Generated ${safeText(dateLabel)} • ${members.length} record${members.length === 1 ? '' : 's'}<br>
    This is a system-generated document containing all member information as indicated in System Management. Keep confidential.<br>
    Paper: Short Bond (8.5" x 11" / 215.9mm x 279.4mm) • Official Header & Footer • LSO Database System
  </div>
</div>
<script>
  window.addEventListener('load', () => {
    setTimeout(() => {
      try { window.print(); } catch(e) {}
    }, 600);
  });
  window.addEventListener('afterprint', () => {
    // Optional: close after print on some browsers if opened as popup
    // setTimeout(() => window.close(), 500);
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
    // Focus for print dialog
    try { popup.focus(); } catch {}
    return true;
  }

  function logPrintActivity(stage, count) {
    try {
      window.LSOOperations?.logActivity?.('Printed members directory', 'Members', `${stage} • ${count} record${count===1?'':'s'} • Short Bond • Official Header/Footer`);
    } catch {}
  }

  function handlePrint() {
    const stage = getCurrentStage();
    const members = getFilteredMembersForPrint();

    if (!members.length) {
      window.LSOApp?.showToast?.(`No ${stage} members match the current filters.`, true);
      return;
    }

    // Confirm large print
    if (members.length > 40) {
      const ok = window.confirm(`You are about to print ${members.length} members from ${stage} with full details (all system management fields) on short bond paper with official header/footer.\\n\\nThis will generate a professional multi-page document. Continue?`);
      if (!ok) return;
    }

    try {
      const html = generatePrintHtml(members, stage);
      const opened = openPrintWindow(html);
      if (opened) {
        logPrintActivity(stage, members.length);
        window.LSOApp?.showToast?.(`${stage} directory print prepared: ${members.length} member${members.length===1?'':'s'} on short bond.`);
      }
    } catch (error) {
      console.error('[Members Directory Print] Failed', error);
      window.LSOApp?.showToast?.(error.message || 'Directory print could not be generated.', true);
    }
  }

  function updatePrintButtonLabel() {
    const btn = el('printMembersDirectory');
    if (!btn) return;
    const stage = getCurrentStage();
    const shortLabel = stage.replace(' Period', '');
    const stageSpan = btn.querySelector('.print-stage-label');
    if (stageSpan) stageSpan.textContent = shortLabel;
    btn.title = `Print ${stage} directory with all member information (Short Bond, Official Header/Footer)`;

    // Update disabled state based on filtered count
    const count = getFilteredMembersForPrint().length;
    btn.disabled = count === 0;
    if (count === 0) btn.title = `No ${stage} members match current filters`;
  }

  function wireEvents() {
    const btn = el('printMembersDirectory');
    if (!btn) return;

    btn.addEventListener('click', handlePrint);

    // Update label when stage changes or filters change
    ['memberListMode', 'probationaryTab', 'traineeTab'].forEach(id => {
      el(id)?.addEventListener('click', () => setTimeout(updatePrintButtonLabel, 80));
    });
    ['memberSearch', 'statusFilter', 'sectionFilter', 'positionFilter'].forEach(id => {
      const input = el(id);
      if (!input) return;
      const evt = input.tagName === 'SELECT' ? 'change' : 'input';
      input.addEventListener(evt, () => setTimeout(updatePrintButtonLabel, 120));
    });

    // Also listen to global member changes
    ['lso:members-changed', 'lso:cloud-state-changed'].forEach(name => {
      window.addEventListener(name, () => setTimeout(updatePrintButtonLabel, 200));
    });

    // Initial label
    setTimeout(updatePrintButtonLabel, 400);
  }

  function initialize() {
    if (!el('membersView')) return;
    wireEvents();
    // Expose for debugging / external calls
    window.LSOMembersDirectoryPrint = {
      print: handlePrint,
      getCurrentStage,
      getFilteredMembers: getFilteredMembersForPrint,
      generateHtml: (stageOverride) => {
        const stage = stageOverride || getCurrentStage();
        const members = getFilteredMembersForPrint();
        return generatePrintHtml(members, stage);
      }
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initialize, { once: true });
  } else {
    initialize();
  }
})();
