/* ============================================================================
   LASALLIAN SYMPHONY ORCHESTRA — V86 ACCOUNTS SEARCH CONSOLE
   File: accounts-search-console-v86.js
   (precached by service-worker-enterprise-v41.js); behaviour level: V86.

   Purpose
     The Accounts module (Administrator → Account Management) renders every
     registered account in one long, scrollable table. As the account list
     grows, an officer has to scroll and read row after row to find one person,
     and the approval queue is buried somewhere in the middle of the list.
     This module adds a professional search console above the table:

       * instant, accent-insensitive search across the account name, username,
         email, role, linked member (name / membership ID / student number /
         section), approving officer, and the request / approval / sign-in
         dates — plus plain-language status words ("pending", "disabled",
         "deactivated", …);
       * status tabs with live counts — All, Needs approval, Active, Rejected,
         Disabled — so the approval queue is one click away;
       * a role filter and six sort orders (priority, name, role, newest
         request, recently approved, recent sign-in);
       * matched text is highlighted, the summary line states exactly what is
         being shown, and an explicit empty state replaces a silent blank;
       * Enter jumps to the first match (and moves focus to that account's
         first control when the search is exact), Esc clears, Ctrl/⌘ + K
         returns to the search field, and clicking a status tab filters.

   Guarantees
     - READ ONLY. This module never calls saveAccounts / deleteAccount and never
       mutates an account object. It reads the account list through
       window.LSOAuth.loadAccounts() (a defensive copy) and only shows or hides
       the <tr> nodes the Accounts module already rendered.
     - management-attendance-member-info-v4.js is NOT modified. renderAccounts()
       keeps owning the markup, the role / linked-member selects, the
       approve / reject / enable / delete buttons, and the delegated listeners
       on #accountsTableBody. This module re-applies the filter after every
       re-render through a MutationObserver on #accountsTableBody.
     - No row is ever removed, re-created, or edited. Filtering only toggles the
       .accounts-row-filtered-out class (display:none), so every action keeps
       its delegated listener, its selected values, and its busy state.
     - Alert deep-links keep working. Clicking "Review Account" in the Action
       Center clears the console filters in the capture phase — before the
       routing handler starts its 60 ms refresh + scroll-to-row — so the
       targeted account can never stay hidden behind a stale filter.
     - No permission, role, account, or database write path is touched; the
       console appears only when the Accounts table actually has data rows
       (i.e. an authorized Administrator), and hides itself otherwise.

   Accessibility
     - The search box is a labelled <input type="search"> described by visible
       hint text; the shortcut is spelled out on screen, never hidden-only.
     - Status tabs are toggle buttons (aria-pressed) inside a labelled group,
       each with aria-controls pointing at the table body, counts announced in
       their accessible name, and ArrowLeft / ArrowRight / Home / End roving
       focus.
     - The result summary is a polite live region; jump / reset feedback uses a
       separate visually hidden live region so it is announced without being
       mistaken for the summary.
     - Hidden rows use display:none (through the class), so screen readers skip
       them exactly like the visual table does.
     - prefers-reduced-motion disables the row flash animation (see the V86 CSS
       layer in lso-ui-bundle-v73.css).

   Mobile / responsive
     - One column below 980px, filters stack below 460px, status tabs scroll
       horizontally with snap points on phones.
     - Every control inherits the V75 44px touch targets and the V74/V75 16px
       input floor, so responsive-audit guards G5 (iOS zoom) and G7 (tap
       targets) stay green for #accountsView.

   Data sources (read-only)
     - window.LSOAuth.loadAccounts()          -> account records
     - window.LSOApp.getMembers()             -> linked member directory
     - window.LSOOperations.getMembers()      -> member fallback
     - sessionStorage 'lso_accounts_search_v86' -> status / role / sort only
       (the free-text query is never persisted)
   ============================================================================ */
(() => {
  'use strict';

  const VIEW_ID = 'accountsView';
  const CONSOLE_ID = 'accountsSearchConsole';
  const TABLE_BODY_ID = 'accountsTableBody';
  const PREFS_KEY = 'lso_accounts_search_v86';
  const HIDDEN_ROW_CLASS = 'accounts-row-filtered-out';
  const FLASH_CLASS = 'accounts-row-focus-flash';
  const HIT_CLASS = 'accounts-search-hit';
  const PLACEHOLDER_ATTR = 'data-accounts-search-empty';
  const STATUS_ORDER = ['all', 'pending', 'active', 'rejected', 'disabled'];
  const STATUS_COPY = {
    all: 'All accounts',
    pending: 'Needs approval',
    active: 'Active',
    rejected: 'Rejected',
    disabled: 'Disabled'
  };
  const STATUS_KEYWORDS = {
    pending: 'pending awaiting approval needs approval unapproved for review to review',
    active: 'active enabled approved account in good standing',
    rejected: 'rejected denied declined refused turned down',
    disabled: 'disabled deactivated inactive suspended switched off'
  };
  const SORT_OPTIONS = {
    priority: 'Priority — needs action',
    name: 'Account name (A–Z)',
    role: 'Role (A–Z)',
    requested: 'Newest request first',
    approved: 'Recently approved',
    login: 'Most recent sign-in'
  };
  const SORTS = Object.keys(SORT_OPTIONS);
  /* Text inside these elements is never rewritten for highlighting. */
  const HIGHLIGHT_SKIP = 'select, option, button, input, textarea, script, style, svg, mark, code, kbd';

  const state = { query: '', status: 'all', role: '', sort: 'priority' };
  const refs = {};
  let sequenceIds = new Map();
  let sequenceNodes = new WeakSet();
  let scheduledFrame = 0;
  let roleOptionSignature = '';

  /* ------------------------------------------------------------------ utils */
  const el = (id) => document.getElementById(id);
  const qs = (selector, root = document) => root.querySelector(selector);
  const qsa = (selector, root = document) => [...root.querySelectorAll(selector)];
  const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[character]));
  const accentFold = (value) => String(value ?? '')
    .toLowerCase()
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/\s+/g, ' ')
    .trim();
  const stamp = (value) => {
    const raw = String(value || '').slice(0, 10);
    return /^\d{4}-\d{2}-\d{2}$/.test(raw) ? raw : '';
  };
  const prefersReducedMotion = () => Boolean(window.matchMedia?.('(prefers-reduced-motion: reduce)')?.matches);
  const isTypingTarget = (node) => {
    if (!(node instanceof Element)) return false;
    if (node.isContentEditable) return true;
    return /^(INPUT|SELECT|TEXTAREA)$/.test(node.tagName);
  };

  let monthFormatter = null;
  let shortFormatter = null;
  function dateWords(value) {
    const raw = stamp(value);
    if (!raw) return '';
    const parsed = new Date(`${raw}T00:00:00`);
    if (Number.isNaN(parsed.getTime())) return '';
    try {
      monthFormatter = monthFormatter || new Intl.DateTimeFormat('en-PH', { month: 'long', day: 'numeric', year: 'numeric' });
      shortFormatter = shortFormatter || new Intl.DateTimeFormat('en-PH', { month: 'short', day: 'numeric', year: 'numeric' });
      return `${shortFormatter.format(parsed)} ${monthFormatter.format(parsed)}`;
    } catch {
      return raw;
    }
  }

  function getRefs() {
    refs.console = refs.console || el(CONSOLE_ID);
    refs.view = refs.view || el(VIEW_ID);
    refs.body = refs.body || el(TABLE_BODY_ID);
    refs.input = refs.input || el('accountSearchInput');
    refs.clear = refs.clear || el('accountSearchClear');
    refs.reset = refs.reset || el('accountSearchReset');
    refs.role = refs.role || el('accountsRoleFilter');
    refs.sort = refs.sort || el('accountsSortSelect');
    refs.tabs = refs.tabs || el('accountsStatusTabs');
    refs.status = refs.status || el('accountsSearchStatus');
    refs.hint = refs.hint || el('accountsSearchHint');
    refs.kbd = refs.kbd || el('accountsSearchKbd');
    refs.announcement = refs.announcement || el('accountsSearchAnnouncement');
    refs.scroller = refs.scroller || qs('#accountsView .accounts-workspace-panel > .table-wrap');
    return refs;
  }

  /* ------------------------------------------------------- account metadata */
  function members() {
    if (typeof window.LSOApp?.getMembers === 'function') return window.LSOApp.getMembers() || [];
    if (typeof window.LSOOperations?.getMembers === 'function') return window.LSOOperations.getMembers() || [];
    return [];
  }

  function memberIndex() {
    const map = new Map();
    members().forEach((member) => map.set(String(member.id), member));
    return map;
  }

  /* Mirrors management-attendance-member-info-v4.js: the default administrator
     is always approved, unknown approval values count as approved. */
  function statusOf(account) {
    if (!account) return '';
    const approval = account.isDefault
      ? 'Approved'
      : (['Pending', 'Approved', 'Rejected'].includes(account.approvalStatus) ? account.approvalStatus : 'Approved');
    if (approval === 'Pending') return 'pending';
    if (approval === 'Rejected') return 'rejected';
    if (account.disabled) return 'disabled';
    return 'active';
  }

  function haystackOf(account, memberMap) {
    const status = statusOf(account) || 'active';
    const member = account.memberId ? memberMap.get(String(account.memberId)) : null;
    const requested = account.requestedAt || account.createdAt;
    const parts = [
      account.displayName, account.username, account.email, account.role, account.memberId,
      account.approvedBy, account.rejectedBy, account.requestedBy,
      status, STATUS_COPY[status], STATUS_KEYWORDS[status],
      member?.fullName, member?.membershipId, member?.studentNumber, member?.outlook,
      member?.orchestraSection, member?.primaryInstrument, member?.periodGroup,
      account.approvedAt ? 'approved approval decided' : '',
      status === 'pending' ? 'requested registered awaiting' : 'requested registered',
      account.lastLoginAt ? 'signed in last login activity' : 'never signed in no login yet',
      dateWords(requested), dateWords(account.approvedAt), dateWords(account.lastLoginAt),
      requested, account.approvedAt, account.lastLoginAt
    ];
    return accentFold(parts.filter(Boolean).join(' '));
  }

  /* Fallback text when an account record is not in the loaded list: read only
     the identifying columns, never the action buttons, so a search for
     "delete" can never match every row. */
  function rowFallbackText(row) {
    const cells = qsa('td', row).slice(0, 5);
    return accentFold(cells.map((cell) => {
      const clone = cell.cloneNode(true);
      qsa('select, option, button', clone).forEach((node) => node.remove());
      return clone.textContent || '';
    }).join(' '));
  }

  function buildEntries(rows) {
    const accounts = new Map();
    (window.LSOAuth?.loadAccounts?.() || []).forEach((account) => accounts.set(String(account.id), account));
    const memberMap = memberIndex();
    return rows.map((row) => {
      const id = String(row.dataset.accountRow || '');
      const account = accounts.get(id) || null;
      const fallback = account ? '' : rowFallbackText(row);
      return {
        id,
        row,
        account,
        status: account ? statusOf(account) : '',
        role: String(account?.role || ''),
        name: accentFold(account?.displayName || account?.username || fallback),
        haystack: account ? haystackOf(account, memberMap) : fallback,
        requested: stamp(account?.requestedAt || account?.createdAt),
        approved: stamp(account?.approvedAt),
        login: stamp(account?.lastLoginAt)
      };
    });
  }

  function searchTerms() {
    return accentFold(state.query).split(' ').filter(Boolean);
  }

  function matchesEntry(entry, terms) {
    if (state.status !== 'all' && entry.status && entry.status !== state.status) return false;
    if (state.role && entry.role !== state.role) return false;
    return terms.every((term) => entry.haystack.includes(term));
  }

  /* -------------------------------------------------------------- rendering */
  function setConsoleVisible(visible) {
    if (!refs.console) return;
    refs.console.classList.toggle('hidden', !visible);
  }

  function cleanupRows(rows) {
    rows.forEach((row) => {
      row.classList.remove(HIDDEN_ROW_CLASS, FLASH_CLASS);
      clearHighlights(row);
    });
    refs.body?.querySelector(`tr[${PLACEHOLDER_ATTR}]`)?.remove();
    placeholderSignature = '';
  }

  /* "Priority" keeps the order renderAccounts() produced (Pending first, then
     newest request). That base order is captured from the row ELEMENTS: a real
     re-render always replaces the <tr> nodes, while the console's own sorting
     only moves the same nodes — so the console can never mistake its own sort
     for a new base order. */
  function syncSequence(rows) {
    const freshRender = rows.some((row) => !sequenceNodes.has(row));
    if (!freshRender) return;
    sequenceNodes = new WeakSet();
    sequenceIds = new Map();
    rows.forEach((row, index) => {
      sequenceNodes.add(row);
      sequenceIds.set(String(row.dataset.accountRow || ''), index);
    });
  }

  const seqOf = (entry) => sequenceIds.get(entry.id) ?? 0;

  function newestFirst(left, right) {
    if (left === right) return 0;
    if (!left) return 1;
    if (!right) return -1;
    return right.localeCompare(left);
  }

  function sortEntries(entries) {
    const comparators = {
      priority: (a, b) => seqOf(a) - seqOf(b),
      name: (a, b) => a.name.localeCompare(b.name) || seqOf(a) - seqOf(b),
      role: (a, b) => accentFold(a.role).localeCompare(accentFold(b.role)) || a.name.localeCompare(b.name),
      requested: (a, b) => newestFirst(a.requested, b.requested) || seqOf(a) - seqOf(b),
      approved: (a, b) => newestFirst(a.approved, b.approved) || seqOf(a) - seqOf(b),
      login: (a, b) => newestFirst(a.login, b.login) || seqOf(a) - seqOf(b)
    };
    const comparator = comparators[state.sort] || comparators.priority;
    return [...entries].sort(comparator);
  }

  function reorderRows(entries) {
    if (!refs.body) return;
    /* Never move the row the officer is editing — that would blur the select. */
    if (document.activeElement?.closest?.(`tr[data-account-row]`)) return;
    const desired = entries.map((entry) => entry.row);
    const current = qsa('tr[data-account-row]', refs.body);
    if (current.length === desired.length && current.every((row, index) => row === desired[index])) return;
    const placeholder = refs.body.querySelector(`tr[${PLACEHOLDER_ATTR}]`);
    desired.forEach((row) => refs.body.insertBefore(row, placeholder || null));
  }

  function clearHighlights(row) {
    const marks = qsa(`mark.${HIT_CLASS}`, row);
    if (!marks.length) return;
    const parents = new Set();
    marks.forEach((mark) => {
      const parent = mark.parentNode;
      if (!parent) return;
      parent.replaceChild(document.createTextNode(mark.textContent || ''), mark);
      parents.add(parent);
    });
    parents.forEach((parent) => parent.normalize());
  }

  /* Fold a text node to its searchable form while keeping a 1:1 character map,
     so a folded match ("munoz" -> "Muñoz") can still be highlighted in place. */
  const foldCache = new Map();
  function foldCharacter(character) {
    if (foldCache.has(character)) return foldCache.get(character);
    const folded = character.normalize('NFD').replace(/[\u0300-\u036f]/g, '');
    const result = folded.length === 1 ? folded.toLowerCase() : character.toLowerCase();
    foldCache.set(character, result);
    return result;
  }

  function foldText(text) {
    let folded = '';
    const offsets = [];
    let index = 0;
    for (const character of text) {
      offsets.push(index);
      folded += foldCharacter(character);
      index += character.length;
    }
    offsets.push(text.length);
    return { folded, offsets };
  }

  function highlightTextNode(node, terms) {
    const text = node.nodeValue || '';
    if (text.trim().length < 2) return;
    const { folded, offsets } = foldText(text);
    const ranges = [];
    terms.forEach((term) => {
      if (term.length < 2) return;
      let from = 0;
      while (from <= folded.length - term.length) {
        const at = folded.indexOf(term, from);
        if (at === -1) break;
        ranges.push([offsets[at], offsets[at + term.length]]);
        from = at + term.length;
      }
    });
    if (!ranges.length) return;
    ranges.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    const merged = [];
    ranges.forEach(([start, end]) => {
      const last = merged[merged.length - 1];
      if (last && start <= last[1]) last[1] = Math.max(last[1], end);
      else merged.push([start, end]);
    });
    for (let index = merged.length - 1; index >= 0; index -= 1) {
      const [start, end] = merged[index];
      /* Split from the end so the earlier offsets stay valid: after both splits
         `node` keeps [0, start) and the middle section is [start, end). */
      node.splitText(end);
      const middle = node.splitText(start);
      const mark = document.createElement('mark');
      mark.className = HIT_CLASS;
      middle.parentNode.insertBefore(mark, middle);
      mark.appendChild(middle);
    }
  }

  function paintRow(row, terms) {
    const highlightTerms = terms.filter((term) => term.length >= 2);
    clearHighlights(row);
    if (!highlightTerms.length || !window.NodeFilter) return;
    const walker = document.createTreeWalker(row, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        if (!node.nodeValue || !node.nodeValue.trim()) return NodeFilter.FILTER_REJECT;
        if (node.parentElement?.closest(HIGHLIGHT_SKIP)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    nodes.forEach((node) => highlightTextNode(node, highlightTerms));
  }

  function filterSummaryParts() {
    const parts = [];
    if (state.status !== 'all') parts.push(`Status: ${STATUS_COPY[state.status]}`);
    if (state.role) parts.push(`Role: ${state.role}`);
    if (state.query) parts.push(`Search: “${state.query}”`);
    return parts;
  }

  /* The empty state lives in its own <tr>. It is written ONLY when it is first
     created or when its wording changes, because writing to it on every apply
     would (a) re-trigger the table observer and (b) detach the reset button
     while an officer is reaching for it. */
  let placeholderSignature = '';
  function renderPlaceholder(matchCount) {
    if (!refs.body) return;
    const existing = refs.body.querySelector(`tr[${PLACEHOLDER_ATTR}]`);
    if (matchCount) {
      if (existing) existing.remove();
      placeholderSignature = '';
      return;
    }
    const signature = filterSummaryParts().join(' • ') || 'No filter is active yet.';
    if (existing && signature === placeholderSignature) return;
    const row = existing || document.createElement('tr');
    if (!existing) {
      row.setAttribute(PLACEHOLDER_ATTR, 'true');
      row.className = 'accounts-search-empty';
      refs.body.appendChild(row);
    }
    placeholderSignature = signature;
    row.innerHTML = `<td colspan="8"><div class="empty-state accounts-search-empty-state">
      <div class="empty-icon" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"></circle><path d="m16 16.5 4 4"></path><path d="M8.5 11h5"></path></svg></div>
      <h4>No accounts match this view</h4>
      <p>${escapeHtml(signature)}</p>
      <p class="accounts-search-empty-note">Nothing was changed — the account list and its actions are untouched.</p>
      <button class="button button-secondary" type="button" data-accounts-search-reset="true">Clear search and filters</button>
    </div></td>`;
  }

  function renderCounts(entries) {
    const counts = { all: entries.length, pending: 0, active: 0, rejected: 0, disabled: 0 };
    entries.forEach((entry) => {
      if (entry.status && counts[entry.status] !== undefined) counts[entry.status] += 1;
    });
    Object.entries(counts).forEach(([key, value]) => {
      const node = refs.tabs?.querySelector(`[data-account-count="${key}"]`);
      if (!node) return;
      node.textContent = String(value);
      const tab = node.closest('[data-account-status]');
      if (!tab) return;
      tab.dataset.empty = String(key !== 'all' && value === 0);
      const label = `${STATUS_COPY[key]}: ${value} account${value === 1 ? '' : 's'}`;
      tab.setAttribute('aria-label', label);
    });
  }

  function renderStatus(shown, total) {
    if (!refs.status) return;
    const parts = [];
    parts.push(shown === total
      ? `${total} account${total === 1 ? '' : 's'}`
      : `${shown} of ${total} accounts shown`);
    parts.push(...filterSummaryParts());
    if (state.sort !== 'priority') parts.push(`Sorted: ${SORT_OPTIONS[state.sort]}`);
    if (state.query && shown > 1) parts.push('Press Enter to jump to the first match');
    refs.status.textContent = parts.join(' • ');
  }

  function renderControls() {
    const filtersActive = Boolean(state.query) || state.status !== 'all' || Boolean(state.role) || state.sort !== 'priority';
    refs.clear?.classList.toggle('hidden', !state.query);
    refs.reset?.classList.toggle('hidden', !filtersActive);
    if (refs.role && refs.role.value !== state.role) refs.role.value = state.role;
    if (refs.sort && refs.sort.value !== state.sort) refs.sort.value = state.sort;
    qsa('[data-account-status]', refs.tabs || document).forEach((tab) => {
      const active = tab.dataset.accountStatus === state.status;
      tab.classList.toggle('active', active);
      tab.setAttribute('aria-pressed', String(active));
      tab.setAttribute('tabindex', active ? '0' : '-1');
    });
  }

  function syncRoleOptions() {
    if (!refs.role) return;
    const roles = new Set();
    (window.LSOAuth?.loadAccounts?.() || []).forEach((account) => {
      if (account?.role) roles.add(String(account.role));
    });
    Object.values(window.LSOSystemCore?.ROLES || {}).forEach((role) => { if (role) roles.add(String(role)); });
    const sorted = [...roles].sort((a, b) => accentFold(a).localeCompare(accentFold(b)));
    const signature = sorted.join('|');
    if (signature === roleOptionSignature) return;
    roleOptionSignature = signature;
    const previous = state.role;
    refs.role.innerHTML = ['<option value="">All roles</option>']
      .concat(sorted.map((role) => `<option value="${escapeHtml(role)}">${escapeHtml(role)}</option>`))
      .join('');
    refs.role.value = sorted.includes(previous) ? previous : '';
    if (refs.role.value !== previous) state.role = refs.role.value;
  }

  /* ------------------------------------------------------------ the pipeline */
  function apply(options = {}) {
    const current = getRefs();
    if (!current.body) return;
    const rows = qsa('tr[data-account-row]', current.body);
    const usable = rows.length > 0;
    setConsoleVisible(usable);
    if (!usable) { cleanupRows(rows); return; }

    syncSequence(rows);
    syncRoleOptions();
    const entries = buildEntries(rows);
    const terms = searchTerms();
    const matched = [];
    entries.forEach((entry) => {
      const visible = matchesEntry(entry, terms);
      entry.row.classList.toggle(HIDDEN_ROW_CLASS, !visible);
      if (visible) matched.push(entry);
      else clearHighlights(entry.row);
    });

    reorderRows(sortEntries(entries));
    matched.forEach((entry) => paintRow(entry.row, terms));
    renderPlaceholder(matched.length);
    renderCounts(entries);
    renderStatus(matched.length, entries.length);
    renderControls();
    if (options.resetScroll && current.scroller) current.scroller.scrollTop = 0;
  }

  function scheduleApply(delay = 0) {
    if (scheduledFrame) return;
    const run = () => {
      scheduledFrame = 0;
      apply();
    };
    scheduledFrame = window.requestAnimationFrame(() => {
      if (delay) window.setTimeout(run, delay);
      else run();
    });
  }

  function savePreferences() {
    try {
      window.sessionStorage.setItem(PREFS_KEY, JSON.stringify({ status: state.status, role: state.role, sort: state.sort }));
    } catch { /* storage can be blocked; the console still works for this page */ }
  }

  function restorePreferences() {
    try {
      const raw = window.sessionStorage.getItem(PREFS_KEY);
      if (!raw) return;
      const saved = JSON.parse(raw);
      if (STATUS_ORDER.includes(saved?.status)) state.status = saved.status;
      if (SORTS.includes(saved?.sort)) state.sort = saved.sort;
      if (typeof saved?.role === 'string') state.role = saved.role;
    } catch { /* ignore malformed preferences */ }
  }

  function announce(message) {
    if (!refs.announcement) return;
    refs.announcement.textContent = '';
    window.requestAnimationFrame(() => { refs.announcement.textContent = message; });
  }

  function commit(options = {}) {
    if (refs.input && refs.input.value !== state.query) refs.input.value = state.query;
    apply(options);
    savePreferences();
  }

  function setQuery(next) {
    state.query = String(next ?? '');
    commit({ resetScroll: true });
  }

  function setStatus(next) {
    if (!STATUS_ORDER.includes(next)) return;
    state.status = next;
    commit({ resetScroll: true });
  }

  function resetFilters({ announceResult = false, keepFocus = false } = {}) {
    const hadFilters = Boolean(state.query) || state.status !== 'all' || Boolean(state.role) || state.sort !== 'priority';
    state.query = '';
    state.status = 'all';
    state.role = '';
    state.sort = 'priority';
    commit({ resetScroll: true });
    if (announceResult && hadFilters) announce('All accounts are shown again.');
    if (keepFocus) return;
    if (hadFilters && refs.input && document.activeElement === refs.input) refs.input.blur();
  }

  function focusInput({ select = false } = {}) {
    if (!refs.input) return;
    refs.input.focus({ preventScroll: false });
    if (select) refs.input.select?.();
    refs.console?.classList.remove('hidden');
  }

  function visibleRows() {
    return qsa('tr[data-account-row]', refs.body || document)
      .filter((row) => !row.classList.contains(HIDDEN_ROW_CLASS));
  }

  function flashRow(row) {
    row.classList.remove(FLASH_CLASS);
    void row.offsetWidth;
    row.classList.add(FLASH_CLASS);
    window.setTimeout(() => row.classList.remove(FLASH_CLASS), 2000);
  }

  function jump() {
    const rows = visibleRows();
    if (!rows.length) {
      announce('No account matches the current search.');
      return;
    }
    const first = rows[0];
    first.scrollIntoView({ block: 'center', behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
    flashRow(first);
    if (rows.length === 1) {
      const control = qs('select:not([disabled]), button:not([disabled])', first);
      if (control) {
        window.setTimeout(() => control.focus({ preventScroll: true }), prefersReducedMotion() ? 0 : 240);
        announce(`One account matches. Focus moved to ${control.dataset.accountAction ? 'its actions' : 'its controls'}.`);
      } else {
        announce('One account matches. It is now highlighted.');
      }
      return;
    }
    announce(`${rows.length} accounts match. Jumped to the first one.`);
  }

  function jumpToAccount(accountId) {
    const id = String(accountId ?? '');
    if (!id) return false;
    let row = qsa('tr[data-account-row]', refs.body || document)
      .find((candidate) => String(candidate.dataset.accountRow) === id);
    if (!row) return false;
    if (row.classList.contains(HIDDEN_ROW_CLASS)) resetFilters();
    row = qs(`tr[data-account-row="${window.CSS?.escape ? CSS.escape(id) : id}"]`, refs.body || document) || row;
    row.scrollIntoView({ block: 'center', behavior: prefersReducedMotion() ? 'auto' : 'smooth' });
    flashRow(row);
    return true;
  }

  /* --------------------------------------------------------------- wiring */
  function viewActive() {
    const view = refs.view || el(VIEW_ID);
    return Boolean(view && view.classList.contains('active'));
  }

  function wireControls() {
    refs.input?.addEventListener('input', (event) => {
      state.query = event.target.value;
      apply({ resetScroll: true });
      savePreferences();
    });
    refs.input?.addEventListener('keydown', (event) => {
      if (event.key === 'Enter') { event.preventDefault(); jump(); return; }
      if (event.key === 'Escape') {
        event.preventDefault();
        if (state.query) { setQuery(''); return; }
        const hadFilters = state.status !== 'all' || Boolean(state.role) || state.sort !== 'priority';
        if (hadFilters) { resetFilters(); announce('Filters cleared.'); return; }
        event.target.blur();
      }
    });
    refs.clear?.addEventListener('click', () => { setQuery(''); focusInput(); });
    refs.reset?.addEventListener('click', () => { resetFilters({ announceResult: true }); focusInput(); });
    refs.role?.addEventListener('change', (event) => {
      state.role = event.target.value;
      commit({ resetScroll: true });
      announce(state.role ? `Filtered to the ${state.role} role.` : 'Role filter cleared.');
    });
    refs.sort?.addEventListener('change', (event) => {
      state.sort = SORTS.includes(event.target.value) ? event.target.value : 'priority';
      commit({ resetScroll: true });
    });
    refs.tabs?.addEventListener('click', (event) => {
      const tab = event.target.closest('[data-account-status]');
      if (tab) setStatus(tab.dataset.accountStatus);
    });
    refs.tabs?.addEventListener('keydown', (event) => {
      const keys = ['ArrowLeft', 'ArrowRight', 'Home', 'End'];
      if (!keys.includes(event.key)) return;
      const tabs = qsa('[data-account-status]', refs.tabs);
      const currentIndex = tabs.indexOf(document.activeElement);
      if (currentIndex === -1) return;
      event.preventDefault();
      const nextIndex = event.key === 'Home' ? 0
        : event.key === 'End' ? tabs.length - 1
          : (currentIndex + (event.key === 'ArrowRight' ? 1 : -1) + tabs.length) % tabs.length;
      tabs[nextIndex].focus();
      setStatus(tabs[nextIndex].dataset.accountStatus);
    });
    refs.body?.addEventListener('click', (event) => {
      if (event.target.closest('[data-accounts-search-reset]')) resetFilters({ announceResult: true });
    });
  }

  function wireKeyboard() {
    document.addEventListener('keydown', (event) => {
      if (!viewActive()) return;
      const primary = event.ctrlKey || event.metaKey;
      if (primary && !event.altKey && String(event.key).toLowerCase() === 'k') {
        event.preventDefault();
        focusInput({ select: true });
        return;
      }
      if (event.key === '/' && !primary && !event.altKey && !isTypingTarget(event.target)) {
        event.preventDefault();
        focusInput({ select: true });
      }
    }, true);
  }

  function wireObservers() {
    if (window.MutationObserver && refs.body) {
      /* Only a real change to the account rows (a renderAccounts re-render)
         re-runs the console. The console's own empty-state row and any other
         furniture must never feed the observer back into a loop. */
      new MutationObserver((records) => {
        const meaningful = records.some((record) => [...record.addedNodes, ...record.removedNodes]
          .some((node) => node.nodeType === 1
            && (node.matches?.('tr[data-account-row]') || Boolean(node.querySelector?.('tr[data-account-row]')))));
        if (meaningful) scheduleApply();
      }).observe(refs.body, { childList: true });
    }
    if (window.MutationObserver && refs.view) {
      new MutationObserver(() => scheduleApply()).observe(refs.view, { attributes: true, attributeFilter: ['class', 'hidden'] });
    }
    window.addEventListener('lso:accounts-changed', () => scheduleApply());
    window.addEventListener('lso:cloud-state-changed', () => scheduleApply(60));
    qsa('[data-view="accountsView"]').forEach((button) => {
      button.addEventListener('click', () => scheduleApply(90));
    });
    /* Action Center deep-links ("Review Account") must never land on a hidden
       row: clear the filters in the capture phase, before the routing handler
       schedules its refresh + scrollIntoView. */
    document.addEventListener('click', (event) => {
      if (event.target.closest?.('[data-alert-view="accountsView"]')) resetFilters();
    }, true);
  }

  function updateHint() {
    const isApple = /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent || '');
    const shortcut = `${isApple ? '⌘' : 'Ctrl'} + K`;
    if (refs.kbd) refs.kbd.textContent = `${isApple ? '⌘' : 'Ctrl'} K`;
    if (!refs.hint) return;
    refs.hint.textContent = `Search as you type. Press Enter to jump to the first match, Esc to clear, or ${shortcut} to return to this field.`;
  }

  function init() {
    const current = getRefs();
    if (!current.console || !current.body) return;
    restorePreferences();
    wireControls();
    wireKeyboard();
    wireObservers();
    updateHint();
    syncRoleOptions();
    commit();
  }

  window.LSOAccountSearch = {
    focus: () => focusInput({ select: true }),
    clear: () => resetFilters({ announceResult: true }),
    refresh: () => apply(),
    isActive: () => viewActive(),
    setStatus,
    setQuery,
    setRole: (role) => {
      state.role = String(role ?? '');
      commit({ resetScroll: true });
    },
    setSort: (sort) => {
      state.sort = SORTS.includes(sort) ? sort : 'priority';
      commit({ resetScroll: true });
    },
    jumpToAccount,
    getState: () => ({ ...state, visible: visibleRows().length })
  };

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
