(() => {
  'use strict';

  const el = (id) => document.getElementById(id);
  let lastPdf = null;
  let previewUrl = '';

  const QUESTIONS = [
    {
      number: '1',
      question: 'Tell me about yourself: Introduce yourself creatively in a way that will help us understand who you are beyond the information written on your application form.',
      details: ['Note: Give the applicant 1 minute of preparation for the Creative Introduction.']
    },
    {
      number: '2',
      question: 'Aside from music, what other interests, hobbies, activities, or organizations are important to you?',
      details: ['Follow-up: How do these interests influence you as a person?']
    },
    {
      number: '3',
      question: 'What are your biggest dreams or goals in life?',
      details: ['Follow-up: What are you currently doing to work toward that goal?']
    },
    {
      number: '4',
      question: 'Give three (3) positive qualities or traits that describe you. For each trait, briefly provide an example of a time when you demonstrated it.',
      details: []
    },
    {
      number: '5',
      question: 'Give three (3) negative qualities or traits that describe you. For each trait, briefly provide an example of a time when you demonstrated it.',
      details: []
    },
    {
      number: '6',
      question: 'Tell us about a time when someone corrected or criticized your performance, behavior, or work.',
      details: ['- How did you initially react?', '- What did you do afterward?', '- What did you learn from the experience?']
    },
    {
      number: '7',
      question: 'Why do you want to join the Lasallian Symphony Orchestra?',
      details: ['Follow-up questions:', '1. What do you know about LSO?', '2. What do you understand about our organization aside from performances and concerts?', '3. What specifically attracted you to this organization?']
    },
    {
      number: '8',
      question: 'Why should we consider accepting you into LSO?',
      details: ['As a musician:', '- What musical skills, experience, discipline, or qualities can you contribute?', 'Outside music:', '- What other skills can you contribute to the organization?', '- Examples may include leadership, documentation, logistics, communications, creatives, event management, technical work, organization, or teamwork.']
    },
    {
      number: '9',
      question: 'On a scale of 1 to 10, with 10 being the highest, how would you rate the level of commitment you are willing to give to the organization? Why?',
      details: [
        'a. Based on your current priorities, how would you rank the following from 1 to 5, with 1 being your highest priority: Academics, Family, Friends, Organization, and, if applicable, Love Life? Please explain your ranking.',
        'b. Suppose you encounter a serious problem involving your highest-priority responsibility - or your second-highest priority if the organization is ranked first. How do you think that situation would affect your participation and continued commitment to the organization?',
        'c. How would you communicate and manage the situation to minimize its impact on your responsibilities within the organization?'
      ]
    },
    {
      number: '10',
      question: 'If you were given a task with strict time constraints, would you rather be late but provide a flawless output or be on time but produce a mediocre output?',
      details: ['Panel should observe whether the applicant mentions:', '- Communication', '- Prioritization', '- Asking for assistance when necessary', '- Accountability', '- Meeting essential requirements', '- Avoiding last-minute excuses']
    },
    {
      number: '11',
      question: 'If you were placed in a leadership role, would you rather be respected by your peers but seen as unapproachable, or be approachable and comfortable to work with but not fully respected as a leader? Why?',
      details: []
    },
    {
      number: '12',
      question: 'What are some of your pet peeves or behaviors from others that you find difficult to deal with?',
      details: ['a. Suppose one of your batchmates repeatedly does one of the things you mentioned. How would you handle the situation while maintaining a respectful and professional relationship with them?']
    },
    {
      number: '13',
      question: 'What do you expect from the organization? What specific qualities or behaviors do you expect from the officers, senior members, and your prospective batchmates?',
      details: ['a. Are you familiar with the concept of seniority within an organization? Given your expectations, how do you think you would adjust to and work within that system?']
    },
    {
      number: '14',
      question: 'What would you do if you were not accepted to the Lasallian Symphony Orchestra?',
      details: []
    },
    {
      number: '15',
      question: 'Imagine that you are physically tired, academically stressed, and experiencing personal problems, but LSO also has an important upcoming commitment.',
      details: ['How would you manage yourself and communicate your situation?']
    },
    {
      number: '16',
      question: 'Do you know your panel?',
      details: ['a. What are our positions?', 'b. What instruments do we play?']
    }
  ];

  function account() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function canAccess() {
    return window.LSORoleAccess?.canAccessView?.('interviewView', account()) ?? account()?.role === 'Administrator';
  }

  function showMessage(message = '', error = false) {
    const node = el('interviewFormMessage');
    if (!node) return;
    node.textContent = message;
    node.classList.toggle('hidden', !message);
    node.classList.toggle('is-error', Boolean(error));
  }

  function values() {
    return {
      name: String(el('interviewName')?.value || '').trim(),
      studentNumber: String(el('interviewStudentNumber')?.value || '').trim(),
      schedule: String(el('interviewSchedule')?.value || '').trim(),
      venue: String(el('interviewVenue')?.value || '').trim(),
      time: String(el('interviewTime')?.value || '').trim()
    };
  }

  function validate(data) {
    const fields = [
      ['name', 'Name'], ['studentNumber', 'Student Number'], ['schedule', 'Schedule'], ['venue', 'Venue'], ['time', 'Time']
    ];
    const missing = fields.filter(([key]) => !data[key]).map(([, label]) => label);
    if (missing.length) throw new Error(`Complete the required field${missing.length === 1 ? '' : 's'}: ${missing.join(', ')}.`);
  }

  function safeFilename(value) {
    return String(value || 'Applicant').replace(/[^a-z0-9_-]+/gi, '_').replace(/^_+|_+$/g, '').slice(0, 70) || 'Applicant';
  }

  function wrapText(text, font, size, maxWidth) {
    const words = String(text || '').split(/\s+/).filter(Boolean);
    const lines = [];
    let line = '';
    words.forEach((word) => {
      const next = line ? `${line} ${word}` : word;
      if (font.widthOfTextAtSize(next, size) <= maxWidth) {
        line = next;
      } else {
        if (line) lines.push(line);
        if (font.widthOfTextAtSize(word, size) <= maxWidth) {
          line = word;
        } else {
          let part = '';
          for (const char of word) {
            const candidate = part + char;
            if (font.widthOfTextAtSize(candidate, size) <= maxWidth) part = candidate;
            else {
              if (part) lines.push(part);
              part = char;
            }
          }
          line = part;
        }
      }
    });
    if (line) lines.push(line);
    return lines.length ? lines : [''];
  }

  function fittedSize(text, font, preferredSize, maxWidth, minSize = 7.2) {
    let size = preferredSize;
    while (size > minSize && font.widthOfTextAtSize(String(text || ''), size) > maxWidth) size -= 0.25;
    return Math.max(size, minSize);
  }

  function decodeEmbeddedAsset(path) {
    const encoded = window.LSO_OFFICIAL_PDF_ASSETS?.[path];
    if (!encoded || typeof encoded !== 'string') return null;
    try {
      const binary = window.atob(encoded);
      const bytes = new Uint8Array(binary.length);
      for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
      return bytes;
    } catch (error) {
      console.error(`[Interview PDF] Embedded asset decode failed for ${path}.`, error);
      return null;
    }
  }

  async function fetchAsset(path) {
    // Prefer the embedded official branding bundle. This makes PDF generation work
    // from GitHub Pages, installed/offline PWAs, and direct local file testing
    // without depending on a browser fetch() request for PNG files.
    const embedded = decodeEmbeddedAsset(path);
    if (embedded?.length) return embedded;

    // Network/file-server fallback for older deployments that do not yet load
    // official-pdf-assets-v51.js. A direct file:// fetch is intentionally avoided
    // because Chromium blocks it and reports the unhelpful "Failed to fetch" error.
    if (window.location?.protocol === 'file:') {
      throw new Error(`Official PDF branding is unavailable: ${path}. Make sure official-pdf-assets-v51.js is included in the complete LSO package.`);
    }

    try {
      const url = new URL(path, document.baseURI).toString();
      const response = await fetch(url, { cache: 'no-store', credentials: 'same-origin' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return new Uint8Array(await response.arrayBuffer());
    } catch (error) {
      console.error(`[Interview PDF] Asset load failed for ${path}.`, error);
      throw new Error(`Official PDF branding could not be loaded (${path}). Reload the updated LSO package and try again.`);
    }
  }

  async function makePdf() {
    if (!canAccess()) throw new Error('Interview access is not assigned to this role. Ask an Administrator to enable the Interview module in Access Control.');
    if (!window.PDFLib?.PDFDocument) throw new Error('The PDF generator is unavailable. Reload the complete website package.');

    const data = values();
    validate(data);
    showMessage('Generating official LSO interview document...');

    const { PDFDocument, StandardFonts, rgb } = window.PDFLib;
    const pdf = await PDFDocument.create();
    pdf.setTitle('Lasallian Symphony Orchestra | Interview Questions');
    pdf.setAuthor('Lasallian Symphony Orchestra');
    pdf.setSubject('Official Interview Questions');
    pdf.setCreator('LSO Orchestra Management System');

    const regular = await pdf.embedFont(StandardFonts.Helvetica);
    const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const italic = await pdf.embedFont(StandardFonts.HelveticaOblique);
    const [headerBytes, footerBytes] = await Promise.all([
      fetchAsset('lso-official-header.png'),
      fetchAsset('lso-official-footer.png')
    ]);
    const officialHeader = await pdf.embedPng(headerBytes);
    const officialFooter = await pdf.embedPng(footerBytes);

    const pageWidth = 612;
    const pageHeight = 792;
    const marginX = 48;
    const contentWidth = pageWidth - marginX * 2;
    const headerHeight = pageWidth * (285 / 1700);
    const footerHeight = pageWidth * (220 / 1700);
    const contentBottom = footerHeight + 34;

    const BLACK = rgb(0, 0, 0);
    const GREEN = rgb(0.02, 0.31, 0.17);
    const MID_GREEN = rgb(0.09, 0.48, 0.27);
    const PALE_GREEN = rgb(0.945, 0.972, 0.956);
    const LABEL_FILL = rgb(0.955, 0.963, 0.958);
    const RULE = rgb(0.67, 0.70, 0.68);
    const LIGHT_RULE = rgb(0.84, 0.86, 0.85);
    const WHITE = rgb(1, 1, 1);

    let page;
    let y;
    let pageNumber = 0;

    function centeredX(text, font, size) {
      return Math.max(marginX, (pageWidth - font.widthOfTextAtSize(text, size)) / 2);
    }

    function addPage() {
      page = pdf.addPage([pageWidth, pageHeight]);
      pageNumber += 1;

      page.drawImage(officialHeader, {
        x: 0,
        y: pageHeight - headerHeight,
        width: pageWidth,
        height: headerHeight
      });
      page.drawImage(officialFooter, {
        x: 0,
        y: 0,
        width: pageWidth,
        height: footerHeight
      });

      const title = 'Lasallian Symphony Orchestra | Interview Questions';
      const titleSize = 12.5;
      const titleY = pageHeight - headerHeight - 22;
      page.drawText(title, {
        x: centeredX(title, bold, titleSize),
        y: titleY,
        size: titleSize,
        font: bold,
        color: BLACK
      });

      const officialText = 'OFFICIAL DOCUMENT OF LASALLIAN SYMPHONY ORCHESTRA';
      page.drawText(officialText, {
        x: centeredX(officialText, regular, 7.2),
        y: titleY - 15,
        size: 7.2,
        font: regular,
        color: BLACK
      });

      page.drawLine({
        start: { x: marginX, y: titleY - 25 },
        end: { x: pageWidth - marginX, y: titleY - 25 },
        thickness: 1.15,
        color: GREEN
      });

      const footerText = `OFFICIAL DOCUMENT OF LASALLIAN SYMPHONY ORCHESTRA  |  PAGE ${pageNumber}`;
      page.drawText(footerText, {
        x: centeredX(footerText, regular, 6.6),
        y: footerHeight + 8,
        size: 6.6,
        font: regular,
        color: BLACK
      });

      y = titleY - 43;
    }

    function ensureSpace(heightNeeded) {
      if (y - heightNeeded < contentBottom) addPage();
    }

    function sectionTitle(title) {
      const h = 20;
      ensureSpace(h + 8);
      page.drawRectangle({ x: marginX, y: y - h, width: 5, height: h, color: GREEN });
      page.drawText(title, { x: marginX + 12, y: y - 14, size: 9.1, font: bold, color: BLACK });
      page.drawLine({
        start: { x: marginX + 12, y: y - h },
        end: { x: marginX + contentWidth, y: y - h },
        thickness: 0.65,
        color: RULE
      });
      y -= h + 8;
    }

    function valueLines(value, font, size, width, maxLines = 3) {
      let currentSize = size;
      let lines = wrapText(String(value || '-'), font, currentSize, width);
      while (lines.length > maxLines && currentSize > 6.6) {
        currentSize -= 0.2;
        lines = wrapText(String(value || '-'), font, currentSize, width);
      }
      return { size: currentSize, lines: lines.slice(0, maxLines) };
    }

    function drawApplicantTable() {
      const rows = [
        ['NAME', data.name, 'STUDENT NUMBER', data.studentNumber],
        ['SCHEDULE', data.schedule, 'VENUE', data.venue],
        ['TIME', data.time, 'DOCUMENT TYPE', 'Interview Questions']
      ];
      const labelW = 82;
      const valueW = (contentWidth - labelW * 2) / 2;
      const x0 = marginX;
      const x1 = x0 + labelW;
      const x2 = x1 + valueW;
      const x3 = x2 + labelW;
      const x4 = marginX + contentWidth;

      const prepared = rows.map((row) => {
        const left = valueLines(row[1], regular, 9.0, valueW - 14, 2);
        const right = valueLines(row[3], regular, 9.0, valueW - 14, 2);
        const lineCount = Math.max(left.lines.length, right.lines.length);
        const rowH = Math.max(34, 17 + lineCount * 10.4);
        return { row, left, right, rowH };
      });
      const tableH = prepared.reduce((sum, item) => sum + item.rowH, 0);
      ensureSpace(tableH + 6);
      const topY = y;
      const bottomY = topY - tableH;

      page.drawRectangle({
        x: x0,
        y: bottomY,
        width: contentWidth,
        height: tableH,
        color: WHITE,
        borderColor: RULE,
        borderWidth: 0.8
      });

      let rowTop = topY;
      prepared.forEach((item, index) => {
        const rowBottom = rowTop - item.rowH;
        page.drawRectangle({ x: x0 + 0.4, y: rowBottom + 0.4, width: labelW - 0.4, height: item.rowH - 0.8, color: LABEL_FILL });
        page.drawRectangle({ x: x2 + 0.4, y: rowBottom + 0.4, width: labelW - 0.4, height: item.rowH - 0.8, color: LABEL_FILL });

        if (index > 0) {
          page.drawLine({ start: { x: x0, y: rowTop }, end: { x: x4, y: rowTop }, thickness: 0.65, color: RULE });
        }
        [x1, x2, x3].forEach((vx) => {
          page.drawLine({ start: { x: vx, y: rowTop }, end: { x: vx, y: rowBottom }, thickness: 0.65, color: RULE });
        });

        const [leftLabel, leftValue, rightLabel, rightValue] = item.row;
        const labelY = rowTop - 13;
        page.drawText(leftLabel, { x: x0 + 7, y: labelY, size: 6.9, font: bold, color: BLACK });
        page.drawText(rightLabel, { x: x2 + 7, y: labelY, size: 6.9, font: bold, color: BLACK });

        function drawValue(block, valueX) {
          const lineH = block.size + 2;
          const blockH = block.lines.length * lineH - 2;
          let yy = rowBottom + (item.rowH - blockH) / 2 + blockH - block.size;
          block.lines.forEach((line) => {
            page.drawText(line, { x: valueX + 7, y: yy, size: block.size, font: regular, color: BLACK });
            yy -= lineH;
          });
        }
        drawValue(item.left, x1);
        drawValue(item.right, x3);
        rowTop = rowBottom;
      });
      y = bottomY - 12;
    }

    function drawBrief() {
      const purpose = "The interview aims to assess the applicant's character, motivation, commitment, communication, teamwork, coachability, and overall suitability for membership in the Lasallian Symphony Orchestra, complementing the musical assessment conducted during the audition.";
      const reminder = 'Ask for permission to record. Do not proceed with the recorded interview unless consent has been given.';
      const purposeLines = wrapText(purpose, regular, 8.4, contentWidth - 22);
      const reminderLines = wrapText(reminder, italic, 8.1, contentWidth - 30);
      const purposeH = 12 + purposeLines.length * 10.0;
      const reminderH = 12 + reminderLines.length * 9.6;
      const totalH = purposeH + reminderH + 14;
      ensureSpace(totalH);

      page.drawText('Purpose', { x: marginX, y: y - 8, size: 7.4, font: bold, color: GREEN });
      let yy = y - 21;
      purposeLines.forEach((line) => {
        page.drawText(line, { x: marginX, y: yy, size: 8.4, font: regular, color: BLACK });
        yy -= 10.0;
      });
      yy -= 4;
      page.drawLine({ start: { x: marginX, y: yy + 8 }, end: { x: marginX + 3, y: yy + 8 }, thickness: 13, color: MID_GREEN });
      page.drawText('Recording reminder', { x: marginX + 10, y: yy + 5, size: 7.1, font: bold, color: BLACK });
      yy -= 7;
      reminderLines.forEach((line) => {
        page.drawText(line, { x: marginX + 10, y: yy, size: 8.1, font: italic, color: BLACK });
        yy -= 9.6;
      });
      y = yy - 9;
    }

    function prepareQuestion(question) {
      const numberW = 28;
      const textW = contentWidth - numberW - 10;
      const mainLines = wrapText(question.question, regular, 9.0, textW);
      const detailGroups = question.details.map((detail) => wrapText(detail, regular, 8.15, textW - 10));
      let h = Math.max(24, mainLines.length * 10.7 + 5);
      if (detailGroups.length) h += 4;
      detailGroups.forEach((lines, i) => {
        h += lines.length * 9.5;
        if (i < detailGroups.length - 1) h += 1;
      });
      h += 8;
      return { numberW, textW, mainLines, detailGroups, height: h };
    }

    function drawQuestion(question) {
      const q = prepareQuestion(question);
      ensureSpace(q.height + 5);
      const topY = y;
      const bottomY = y - q.height;
      const numText = String(question.number).padStart(2, '0');
      page.drawText(numText, { x: marginX, y: topY - 13, size: 8.3, font: bold, color: GREEN });
      page.drawLine({
        start: { x: marginX + 24, y: topY - 2 },
        end: { x: marginX + 24, y: bottomY + 5 },
        thickness: 0.8,
        color: LIGHT_RULE
      });

      let yy = topY - 12;
      const tx = marginX + 34;
      q.mainLines.forEach((line) => {
        page.drawText(line, { x: tx, y: yy, size: 9.0, font: regular, color: BLACK });
        yy -= 10.7;
      });
      if (q.detailGroups.length) yy -= 3;
      q.detailGroups.forEach((lines, groupIndex) => {
        lines.forEach((line) => {
          page.drawText(line, { x: tx + 8, y: yy, size: 8.15, font: regular, color: BLACK });
          yy -= 9.5;
        });
        if (groupIndex < q.detailGroups.length - 1) yy -= 1;
      });

      page.drawLine({
        start: { x: marginX + 34, y: bottomY + 2 },
        end: { x: marginX + contentWidth, y: bottomY + 2 },
        thickness: 0.5,
        color: LIGHT_RULE
      });
      y = bottomY - 3;
    }

    function drawFinalQuestion() {
      const text = 'Is there anything about yourself, your experience, your abilities, or your character that we have not asked about, but you believe the panel should know before making its decision?';
      const lines = wrapText(text, regular, 9.0, contentWidth - 34);
      const h = 26 + lines.length * 10.7;
      ensureSpace(20 + 8 + h);
      sectionTitle('FINAL QUESTION FOR THE APPLICANT');
      page.drawRectangle({ x: marginX, y: y - h, width: contentWidth, height: h, color: PALE_GREEN, borderColor: RULE, borderWidth: 0.7 });
      page.drawText('Q', { x: marginX + 10, y: y - 18, size: 9.0, font: bold, color: GREEN });
      let yy = y - 17;
      lines.forEach((line) => {
        page.drawText(line, { x: marginX + 30, y: yy, size: 9.0, font: regular, color: BLACK });
        yy -= 10.7;
      });
      y -= h + 10;
    }

    function drawOtherDetailsTable() {
      const rowH = 34;
      const labelW = 125;
      const half = contentWidth / 2;
      const h = rowH * 2;
      ensureSpace(h + 6);
      const topY = y;
      const bottomY = y - h;
      page.drawRectangle({ x: marginX, y: bottomY, width: contentWidth, height: h, color: WHITE, borderColor: RULE, borderWidth: 0.8 });
      page.drawLine({ start: { x: marginX, y: topY - rowH }, end: { x: marginX + contentWidth, y: topY - rowH }, thickness: 0.65, color: RULE });
      page.drawLine({ start: { x: marginX + half, y: topY }, end: { x: marginX + half, y: topY - rowH }, thickness: 0.65, color: RULE });
      page.drawLine({ start: { x: marginX + labelW, y: topY }, end: { x: marginX + labelW, y: topY - rowH }, thickness: 0.65, color: RULE });
      page.drawLine({ start: { x: marginX + half + labelW, y: topY }, end: { x: marginX + half + labelW, y: topY - rowH }, thickness: 0.65, color: RULE });
      page.drawRectangle({ x: marginX + 0.4, y: topY - rowH + 0.4, width: labelW - 0.4, height: rowH - 0.8, color: LABEL_FILL });
      page.drawRectangle({ x: marginX + half + 0.4, y: topY - rowH + 0.4, width: labelW - 0.4, height: rowH - 0.8, color: LABEL_FILL });
      page.drawRectangle({ x: marginX + 0.4, y: bottomY + 0.4, width: labelW - 0.4, height: rowH - 0.8, color: LABEL_FILL });
      page.drawText('DATE FOR ORIENTATION', { x: marginX + 7, y: topY - 20, size: 6.9, font: bold, color: BLACK });
      page.drawText('PARENT ORIENTATION', { x: marginX + half + 7, y: topY - 20, size: 6.9, font: bold, color: BLACK });
      page.drawText('BATCH / TERM', { x: marginX + 7, y: topY - rowH - 20, size: 6.9, font: bold, color: BLACK });
      y = bottomY - 10;
    }

    function drawWritingBox(label, height) {
      ensureSpace(height + 6);
      page.drawRectangle({ x: marginX, y: y - height, width: contentWidth, height, color: WHITE, borderColor: RULE, borderWidth: 0.8 });
      page.drawRectangle({ x: marginX, y: y - 20, width: contentWidth, height: 20, color: LABEL_FILL });
      page.drawLine({ start: { x: marginX, y: y - 20 }, end: { x: marginX + contentWidth, y: y - 20 }, thickness: 0.6, color: RULE });
      page.drawText(label, { x: marginX + 8, y: y - 14, size: 7.2, font: bold, color: BLACK });
      y -= height + 7;
    }

    function drawSignatureTable() {
      const h = 44;
      const half = contentWidth / 2;
      ensureSpace(h + 4);
      page.drawRectangle({ x: marginX, y: y - h, width: contentWidth, height: h, color: WHITE, borderColor: RULE, borderWidth: 0.8 });
      page.drawLine({ start: { x: marginX + half, y }, end: { x: marginX + half, y: y - h }, thickness: 0.65, color: RULE });
      page.drawText('INTERVIEW PANEL SIGNATURE', { x: marginX + 8, y: y - 13, size: 6.9, font: bold, color: BLACK });
      page.drawText('DATE', { x: marginX + half + 8, y: y - 13, size: 6.9, font: bold, color: BLACK });
      page.drawLine({ start: { x: marginX + 18, y: y - 31 }, end: { x: marginX + half - 18, y: y - 31 }, thickness: 0.55, color: RULE });
      page.drawLine({ start: { x: marginX + half + 18, y: y - 31 }, end: { x: marginX + contentWidth - 18, y: y - 31 }, thickness: 0.55, color: RULE });
      y -= h + 6;
    }

    addPage();
    sectionTitle('APPLICANT INFORMATION');
    drawApplicantTable();
    drawBrief();
    sectionTitle('INTERVIEW QUESTIONS');
    QUESTIONS.forEach(drawQuestion);
    drawFinalQuestion();

    sectionTitle('PANEL NOTES AND RECOMMENDATIONS');
    drawOtherDetailsTable();

    addPage();
    sectionTitle('PANEL ASSESSMENT');
    drawWritingBox('STRENGTH/S OBSERVED', 96);
    drawWritingBox('AREAS FOR IMPROVEMENT', 96);
    drawWritingBox('FINAL RECOMMENDATION', 78);
    drawSignatureTable();

    lastPdf = await pdf.save();
    return { bytes: lastPdf, data };
  }

  function showPreview(bytes) {
    if (previewUrl) URL.revokeObjectURL(previewUrl);
    previewUrl = URL.createObjectURL(new Blob([bytes], { type: 'application/pdf' }));
    const frame = el('interviewPreview');
    if (frame) {
      frame.src = previewUrl;
      frame.classList.remove('hidden');
    }
    el('interviewPreviewPlaceholder')?.classList.add('hidden');
    const status = el('interviewPreviewStatus');
    if (status) status.textContent = 'Official preview ready';
  }

  async function generatePreview() {
    try {
      const { bytes } = await makePdf();
      showPreview(bytes);
      showMessage('Official LSO interview document generated successfully.');
      window.LSOApp?.showToast?.('Official interview preview generated.');
    } catch (error) {
      showMessage(error.message || 'The interview PDF could not be generated.', true);
      window.LSOApp?.showToast?.(error.message || 'The interview PDF could not be generated.', true);
    }
  }

  async function downloadPdf() {
    try {
      const data = values();
      validate(data);
      if (!lastPdf) {
        const result = await makePdf();
        showPreview(result.bytes);
      }
      const url = URL.createObjectURL(new Blob([lastPdf], { type: 'application/pdf' }));
      const link = document.createElement('a');
      link.href = url;
      link.download = `LSO_Official_Interview_${safeFilename(data.name)}.pdf`;
      document.body.appendChild(link);
      link.click();
      link.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 2000);
      showMessage('Official LSO interview PDF downloaded successfully.');
      window.LSOOperations?.logActivity?.('Generated interview template', 'Interview', `${data.name} | ${data.studentNumber} | ${data.schedule}`);
    } catch (error) {
      showMessage(error.message || 'The interview PDF could not be downloaded.', true);
      window.LSOApp?.showToast?.(error.message || 'The interview PDF could not be downloaded.', true);
    }
  }

  function invalidatePreview() {
    lastPdf = null;
    const status = el('interviewPreviewStatus');
    if (status) status.textContent = 'Details changed - regenerate preview';
  }

  function initialize() {
    el('generateInterviewPdf')?.addEventListener('click', generatePreview);
    el('downloadInterviewPdf')?.addEventListener('click', downloadPdf);
    ['interviewName', 'interviewStudentNumber', 'interviewSchedule', 'interviewVenue', 'interviewTime'].forEach((id) => {
      const field = el(id);
      field?.addEventListener('input', invalidatePreview);
      field?.addEventListener('change', invalidatePreview);
    });
  }

  window.LSOInterviewManager = Object.freeze({
    createOfficialPdf: makePdf,
    generatePreview,
    downloadPdf,
    invalidatePreview
  });

  window.addEventListener('beforeunload', () => { if (previewUrl) URL.revokeObjectURL(previewUrl); });
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', initialize, { once: true });
  else initialize();
})();
