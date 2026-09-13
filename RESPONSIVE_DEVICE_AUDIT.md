# LSO Orchestra Management System — Cross-Device Responsiveness & Behaviour Audit

**Date:** 2026-09-13 • **Engine:** real Chromium 153.0.8010.0 (headless, driven over the Chrome DevTools Protocol) • **Profiles:** 17 device classes from 280 px to 2560 px, portrait + landscape, touch + mouse • **Coverage:** login screen, 11 app views, navigation drawer, member modal, orientation flips, per-view layout probes

> **Method.** The audit loads the *production* `index.html` and drives it through its real code paths — real login (against a faithful Supabase RPC mock, because the Supabase project is unreachable from the audit sandbox), real role gating (`Administrator`), real view switching, drawers, modals and every shipped stylesheet. The mock implements the exact RPC contract (`lso_login`, `lso_get_state`, `lso_list_accounts`, `lso_ping`, …) and returns a realistic dataset (34 members, 90 duty entries, 16 accounts, 12 events) so every table renders populated. Raw measurements: `rt-test/results/results.json`; screenshots: `rt-test/results/shots/`; browsable gallery: serve `rt-test/results/` and open `gallery.html`.

## 1. Verdict

The site is **responsive and well-behaved on phones (320–430 px) and on mouse-driven laptops/desktops (1280–2560 px)**: zero page-level horizontal overflow, no scroll-lock leaks, correct drawer/modal behaviour, correct `dvh`/safe-area handling and zero console errors across 187 view measurements.

It is **broken on one large and very common device class: touch screens wider than 920 px** — iPad in landscape, iPad Pro 12.9" portrait, Surface/Windows touch laptops. There the entire application renders inside a **268 px column** with the rest of the screen left blank and hundreds of pixels of each panel clipped and unreachable (finding **F0**, screenshot below). A second cluster of issues hides the topbar's primary actions on phones (**F1**) and lets form fields show through the modal's Save/Cancel bar (**F2**).

## 2. Headline matrix

| Device | Class | Page H-overflow | Content-column collapse | Clipped content (>60px) | Tap <44 | Tap <24 | Inputs <16px | Drawer | Modal | Flip |
|---|---|---|---|---|---|---|---|---|---|---|
| Galaxy Fold (cover screen) (280×653) | touch | ❌ 40px | ✅ | ✅ | ⚠️ 12 | ✅ | ⚠️ 8 | ✅ | ✅ | ✅ |
| iPhone SE 1st gen (smallest common iOS) (320×568) | touch | ✅ | ✅ | ✅ | ⚠️ 12 | ✅ | ⚠️ 8 | ✅ | ✅ | ✅ |
| Typical Android phone (360dp) (360×740) | touch | ✅ | ✅ | ✅ | ⚠️ 12 | ✅ | ⚠️ 8 | ✅ | ✅ | ✅ |
| iPhone 14 / 15 (390dp) (390×844) | touch | ✅ | ✅ | ✅ | ⚠️ 12 | ✅ | ⚠️ 8 | ✅ | ✅ | ✅ |
| Pixel 7 (412dp) (412×915) | touch | ✅ | ✅ | ✅ | ⚠️ 12 | ✅ | ⚠️ 8 | ✅ | ✅ | ✅ |
| iPhone 15 Pro Max (430dp) (430×932) | touch | ✅ | ✅ | ✅ | ⚠️ 12 | ✅ | ⚠️ 8 | ✅ | ✅ | ✅ |
| iPhone 14 landscape (844×390) | touch | ✅ | ✅ | ✅ | ⚠️ 13 | ✅ | ⚠️ 17 | ✅ | ✅ | ✅ |
| Pixel 7 landscape (915×412) | touch | ✅ | ✅ | ✅ | ⚠️ 13 | ✅ | ⚠️ 17 | ✅ | ✅ | ✅ |
| iPad mini portrait (744dp) (744×1133) | touch | ✅ | ✅ | ✅ | ⚠️ 13 | ✅ | ⚠️ 17 | ✅ | ✅ | ✅ |
| iPad 9.7/10.2 portrait (768dp) (768×1024) | touch | ✅ | ✅ | ✅ | ⚠️ 13 | ✅ | ⚠️ 17 | ✅ | ✅ | ✅ |
| iPad Pro 11" landscape (1194dp) (1194×834) | touch | ✅ | ❌ ~268px column | ❌ 10 | ⚠️ 16 | ⚠️ 4 | ⚠️ 17 | — | ✅ | ✅ |
| iPad Pro 12.9" portrait (1024dp) (1024×1366) | touch | ✅ | ❌ ~268px column | ❌ 9 | ⚠️ 14 | ⚠️ 3 | ⚠️ 17 | — | ✅ | ✅ |
| Surface Pro / touch laptop (1368dp) (1368×912) | touch | ✅ | ❌ ~268px column | ❌ 10 | ⚠️ 19 | ⚠️ 4 | ⚠️ 17 | — | ✅ | ✅ |
| Small laptop 1280x720 (1280×720) | mouse | ✅ | ✅ | ✅ | — | ✅ | ⚠️ 17 | — | ✅ | — |
| Common laptop 1366x768 (1366×768) | mouse | ✅ | ✅ | ✅ | — | ✅ | ⚠️ 17 | — | ✅ | — |
| Desktop 1920x1080 (1920×1080) | mouse | ✅ | ✅ | ✅ | — | ✅ | ⚠️ 17 | — | ✅ | — |
| Ultra-wide 2560x1080 (2560×1080) | mouse | ✅ | ✅ | ✅ | — | ✅ | ⚠️ 17 | — | ✅ | — |

## 3. Findings, ranked

### 🔴 F0 — CRITICAL: on any touch screen wider than 920 px the whole app collapses into a ~268 px column

**Affected:** iPad Pro 11" landscape (1194 px), iPad Pro 12.9" portrait (1024 px), iPad Air landscape, Surface Pro and every Windows touch laptop above 920 px — i.e. the devices secretaries and staff actually use for data entry.

**Measured (1194×834, coarse pointer, Attendance view):**
- `#appShell` computed `display:grid; grid-template-columns: 268px 926px`; `main.main-content` is **268 px wide**; the 926 px second track stays empty.
- `#sidebar` is `position:fixed` and translated `-346 px` off-canvas (the phone drawer), so it no longer occupies its grid track and `main` auto-places into the empty 268 px track.
- Consequence: `#attendanceSharedGroupControls` shows 213 px of an 850 px panel (**637 px clipped**), `#attendanceCalendarPanel` 213/722, `#dutyApprovalTableBody .duty-punch-review-card` 171/805 (**634 px clipped**), dashboard hero 213/378. All of it inside `overflow:hidden` containers → **unreachable, not scrollable**.
- Same-size viewport with a fine pointer: `main` = 916 px, everything fine. The only difference is `pointer: coarse`.

**Root cause — a CSS/JS contract mismatch:**
1. `lso-ui-bundle-v73.css` line 9384: `@media (max-width: 920px), (pointer: coarse) { … }` applies the *entire phone shell* (line 9520 `.sidebar { position: fixed !important; transform: translate3d(-105%,0,0) !important; … }`, block `#appShell{display:block!important}`) to coarse pointers at **any** width.
2. `auth.js` `unlockApplicationShell()` computes the shell display from width only: `const mobileLayout = window.matchMedia?.('(max-width: 920px)')?.matches; shell.style.setProperty('display', mobileLayout ? 'block' : 'grid', 'important');` → at 1194 px it writes an inline `display:grid !important`, which beats the stylesheet's `display:block !important`, re-creating the two-column grid whose first track the fixed sidebar has vacated.

**Fix (two lines, both required):**
```js
// auth.js — make the JS agree with the CSS shell contract
const mobileLayout = window.matchMedia?.('(max-width: 920px), (pointer: coarse)')?.matches;
```
```css
/* belt & braces inside the same @media (max-width: 920px), (pointer: coarse) block */
.app-shell, #appShell { grid-template-columns: minmax(0, 1fr) !important; }
.main-content { width: 100% !important; max-width: none !important; }
```
Regression guard: `assert(getComputedStyle(main).width > 700)` at 1194×834 with `hasTouch:true`.

Evidence: `results/shots/tablet-collapse-1194-coarse-true.png` (broken) vs `tablet-collapse-1194-coarse-false.png` (same size, mouse).

### 🔴 F1 — Phones: notification bell, accessibility launcher and "+ Add Member" are parked off-screen in a scrollbar-less strip

**Measured (390 px):** `.topbar-actions` box = **96 px** wide (`grid-template-columns: 44px 214px 96px`) with `overflow-x:auto; scrollbar-width:none`; ~5 controls need ~224 px. Visible result: the `STAGING/PRODUCTION` badge + a **half-clipped "Aa" button at the viewport edge**, while `#notificationButton` (56 unread in the test data) and `#addMemberTop` sit at `left 404–498 px`, fully off-screen with no affordance. Identical at 280/320/360/412/430 px.

**Root cause (layered overrides):** `@media (max-width:460px){ .topbar-actions .button:not(#addMemberTop){display:none} }` (line 10958) intends to leave only "+"; but `@media (max-width:760px)` later re-shows everything (line 11087 `.topbar-actions .button,.icon-button,.notification-center{display:inline-flex}`) and turns the cluster into a 142 px scroll strip (lines 11518-11537). Nothing is removed — it is just pushed out of sight.

**Fix:** at ≤680 px show at most 3 controls at real size (drop the badge into the drawer, keep bell + "+" + "Aa"): `.topbar{grid-template-columns:auto minmax(0,1fr) auto} .topbar-actions{max-width:none;overflow:visible;display:flex;gap:6px}`, or move overflow actions into a "⋯" popover. Never combine a sticky toolbar with `overflow-x:auto` + hidden scrollbars.

Evidence: `results/shots/iphone-14-dashboardView.png` (clipped "A" at right edge), `android-360-*.png`.

### 🟠 F2 — Phones: the member modal's sticky Save/Cancel bar is transparent, form fields scroll through the buttons

**Measured (390 px, Edit Member Record):** `.modal-footer` is `position:sticky; bottom:0; background:inherit` (line 5846, inside `@media (max-width:680px)`); the form behind has no background → inputs and the next `<select>` render *through* the Save/Cancel buttons.
The opaque/blurred footer rule exists but is scoped `.view.active .modal-footer` (line 13719) — `#memberModal` is mounted after `</main>`, outside every `.view`, so it never matches.
**Fix:** `@media (max-width:680px){ .modal-backdrop .modal-footer{ background:#fff; backdrop-filter:blur(6px); border-top:1px solid var(--line); } }` (replaces `background:inherit`).

Evidence: `results/shots/iphone-14-member-modal.png`.

### 🟠 F3 — Below 320 px CSS width the layout floor clips the right edge of the whole app (Galaxy Fold cover screens)

**Measured (280 px):** `document.scrollWidth` = 320 on a 280 px viewport in *every* view and on the login screen → the right **40 px** of `#appShell`/`#authScreen` is cut and unreachable (`html,body{overflow-x:hidden}`), including the right border-radius of inputs and the "Login to Database" button; `#toastRegion` (296 px) overflows by 28 px.
**Root cause:** `html { min-width: 320px }` (lines 534, 9387, 11019).
**Fix:** lower the floor to 280 px (`html{min-width:280px}` + `@media (max-width:320px){ .toast{max-width:calc(100vw - 24px)} .auth-card{padding-inline:12px} }`), or accept 320 px as the documented minimum and state it in the README. 320 px and above are clean (0 px overflow).

Evidence: `results/shots/galaxy-fold-cover-01-login.png`.

### 🟠 F4 — Touch targets under the 44 px guideline (systemic, minor)
| Control | Size | Example views |
|---|---|---|
| `#sidebarCloseButton` (Close navigation) | 44×28 | dashboardView, membersView |
| `tr > td > div.table-actions > button.small-button.approve` (Approve Selected Role) | 163×34 | accountsView |
| `section.dcc-panel.dcc-month-panel > div.dcc-panel-heading > div.dcc-month-controls > button` (Previous month) | 38×38 | dashboardView |
| `#dccMonthPicker`  | 174×38 | dashboardView |
| `#dccMonthPicker`  | 214×38 | dashboardView |
| `#dccMonthPicker`  | 244×38 | dashboardView |
| `#dccMonthPicker`  | 266×38 | dashboardView |
| `#dccMonthPicker`  | 191×38 | dashboardView |
| `#dccMonthPicker`  | 130×38 | dashboardView |
| `#dccMonthPicker`  | 187×38 | dashboardView |

The tightest are the member row-action icon buttons (38×44), month-picker controls and segmented tabs (38-40 px). The `(hover:none),(pointer:coarse)` rule already enforces 44 px for `.button/.nav-item/.icon-button` — extend the selector list to `.table-action, .segment-button, .monthly-report-tab, input[type=month], input[type=date], select, .dcc-month-controls button`.

Additionally on touch **tablets**, `#printDuty*` print buttons measure **22×62 px** and calendar day buttons **22×116 px** (width below WCAG 2.5.8's 24 px minimum) because their labels wrap/clip inside collapsed containers — fixing F0 restores their real size.

### 🟠 F5 — 14 px form controls trigger iOS Safari zoom-on-focus (phones *and* iPads)

17 distinct inputs/selects render at 14 px (Monthly Report setup: `#monthlyReportMonth`, `#monthlyReportDate`, `#monthlyReportSemester`, `#monthlyReportAcademicYear`, `#monthlyReportPreparedBy` …; duty-hours fields). On iPhone/iPad Safari, focusing any control under 16 px zooms the page to ~200 %; the layout "jumps" and users must pinch back. The measurement appears on every touch profile including 1024/1194 px iPads.
**Fix:** `@media (pointer:coarse){ input, select, textarea{ font-size:16px } }`.

### 🟡 F6 — Event-card meta line is fully ellipsised on phones

`#eventList .event-card small` clips up to 291 px of text ("Official Members • First Semester • Sep …") at 320-430 px. Intentional ellipsis, but the whole line disappears on the smallest screens. **Fix:** `@media (max-width:560px){ .event-copy small{ white-space:normal; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical } }`.

### 🟡 F7 — Drawer behaviour is excellent; ARIA state is missing

Verified on all 8 mobile profiles: opens with a real backdrop, locks body scroll, moves focus to the close button, 10 nav targets at 48-49 px, closes via button/Escape/backdrop, **restores the exact scroll position**, and page scrolling works afterwards (the classic mobile scroll-lock leak is absent). Gap: `#mobileMenuButton` never receives `aria-expanded`/`aria-controls`, so assistive tech cannot perceive the drawer state — add the toggle in `mobile-shell-controller-v37.js`.

### 🟡 F8 — Toasts can sit on top of dashboard action cards (desktop)

`#toastRegion` (fixed, bottom-right, z-200) intercepted clicks on `.dcc-action-card` buttons while a toast was visible (hit-test: blocked by `#toastRegion > .toast`). Auto-dismiss is present but the region has no `pointer-events:none` on the container (only per-toast). **Fix:** `.toast-region{pointer-events:none} .toast{pointer-events:auto}`.

### 🟡 F9 — Maintainability debt that produced F0/F1/F2

- Active stylesheet: **4 442 rules**, **34 distinct `max-width` breakpoints** (340→1480) and **1 387 `!important` declarations**; behaviour layers from V36…V73 override each other by source order.
- JS knows only two breakpoints (920 px, 760 px) while CSS uses 34 — the CSS/JS contract drift is exactly what broke F0.
- `instrumentsView` has **no navigation item** (reachable only via a dashboard quick action) yet carries a 940 px `min-width` table; audit whether it should stay user-facing.
- Recommendation: collapse to five tokens (`--bp-xs:480, --bp-sm:680, --bp-md:920, --bp-lg:1180, --bp-xl:1440`), gate every new layer through them, and delete dead versioned layers (the repo ships ~40 superseded `.css`/`.js` files that are not referenced by `index.html`).

## 4. Verified strengths (measured, not assumed)

- **Zero page-level horizontal overflow** at 320-2560 px across all 11 views (the only exception is the documented 320 px floor, F3). The 1 420 px members directory, 1 260 px duty ledger and 980 px accounts table all sit in real `overflow-x:auto` wrappers (7-55 scroll containers detected per view) and switch to stacked card layouts below 760 px.
- **Viewport-unit discipline:** 31 `dvh/svh` declarations for shell, sidebar, modals and auth screen; `env(safe-area-inset-*)` honoured; `viewport-fit=cover`; zoom is *not* blocked (`no user-scalable=no`).
- **Scroll-lock discipline:** body scroll is locked while drawer/modal are open and always released; scroll position preserved across drawer open/close on every mobile profile.
- **Orientation flips are clean:** no stuck inline styles, no lock leaks, no residual drawer state after rotate + rotate-back on all 8 touch profiles.
- **Accessibility scaffolding:** `role=dialog`/`aria-modal` modals, focus moved into the drawer, `(hover:none)/(pointer:coarse)`, `prefers-reduced-motion` (28 rules), `prefers-contrast` (4), `forced-colors` (4), print stylesheet (10 blocks), 44 px touch-target token.
- **Runtime cleanliness:** 0 console errors and 0 page errors across the entire 17-device × 11-view matrix, login included.

## 5. Suggested CI regression guards

Ship `rt-test/harness.js` + `seed.js` + `mock-supabase.js` as a smoke test with these assertions (each maps to a finding it would have caught):
1. `scrollWidth === clientWidth` for every view × device  → protects the no-overflow guarantee (F3).
2. `getComputedStyle(main.main-content).width > 0.7 * innerWidth` at 1194×834 with `hasTouch:true` → catches F0.
3. every visible `.topbar-actions` control has `rect.right <= innerWidth` at 390 px → catches F1.
4. `getComputedStyle(.modal-footer).backgroundColor` opaque while a modal is open at ≤680 px → catches F2.
5. all `input/select/textarea` computed `font-size >= 16px` under `(pointer:coarse)` → catches F5.

## 6. Appendix — per-device measurements

### Galaxy Fold (cover screen) (280×653) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 40 | 0 | 8 | 12 | 0 | 0 | 60 |
| membersView | 40 | 0 | 8 | 5 | 0 | 0 | 14 |
| attendanceView | 40 | 0 | 8 | 6 | 0 | 0 | 45 |
| dutyHoursView | 40 | 0 | 8 | 6 | 0 | 2 | 16 |
| monthlyReportView | 40 | 0 | 8 | 4 | 0 | 8 | 30 |
| accountsView | 40 | 0 | 8 | 3 | 0 | 0 | 20 |
| contractView | 40 | 0 | 8 | 3 | 0 | 0 | 2 |
| interviewView | 40 | 0 | 8 | 3 | 0 | 0 | 2 |
| dataView | 40 | 0 | 8 | 3 | 0 | 0 | 5 |
| systemHealthView | 40 | 0 | 8 | 3 | 0 | 0 | 6 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### iPhone SE 1st gen (smallest common iOS) (320×568) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 12 | 0 | 0 | 2 |
| membersView | 0 | 0 | 8 | 5 | 0 | 0 | 2 |
| attendanceView | 0 | 0 | 8 | 6 | 0 | 0 | 19 |
| dutyHoursView | 0 | 0 | 8 | 6 | 0 | 2 | 2 |
| monthlyReportView | 0 | 0 | 8 | 4 | 0 | 8 | 2 |
| accountsView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| contractView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| interviewView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| dataView | 0 | 0 | 8 | 3 | 0 | 0 | 6 |
| systemHealthView | 0 | 0 | 8 | 3 | 0 | 0 | 6 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### Typical Android phone (360dp) (360×740) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 12 | 0 | 0 | 2 |
| membersView | 0 | 0 | 8 | 5 | 0 | 0 | 2 |
| attendanceView | 0 | 0 | 8 | 6 | 0 | 0 | 19 |
| dutyHoursView | 0 | 0 | 8 | 6 | 0 | 2 | 2 |
| monthlyReportView | 0 | 0 | 8 | 4 | 0 | 8 | 2 |
| accountsView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| contractView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| interviewView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| dataView | 0 | 0 | 8 | 3 | 0 | 0 | 6 |
| systemHealthView | 0 | 0 | 8 | 3 | 0 | 0 | 4 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### iPhone 14 / 15 (390dp) (390×844) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 12 | 0 | 0 | 2 |
| membersView | 0 | 0 | 8 | 5 | 0 | 0 | 2 |
| attendanceView | 0 | 0 | 8 | 6 | 0 | 0 | 16 |
| dutyHoursView | 0 | 0 | 8 | 6 | 0 | 2 | 2 |
| monthlyReportView | 0 | 0 | 8 | 4 | 0 | 8 | 2 |
| accountsView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| contractView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| interviewView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| dataView | 0 | 0 | 8 | 3 | 0 | 0 | 6 |
| systemHealthView | 0 | 0 | 8 | 3 | 0 | 0 | 5 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### Pixel 7 (412dp) (412×915) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 12 | 0 | 0 | 2 |
| membersView | 0 | 0 | 8 | 5 | 0 | 0 | 2 |
| attendanceView | 0 | 0 | 8 | 6 | 0 | 0 | 15 |
| dutyHoursView | 0 | 0 | 8 | 6 | 0 | 2 | 2 |
| monthlyReportView | 0 | 0 | 8 | 4 | 0 | 8 | 2 |
| accountsView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| contractView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| interviewView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| dataView | 0 | 0 | 8 | 3 | 0 | 0 | 6 |
| systemHealthView | 0 | 0 | 8 | 3 | 0 | 0 | 4 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### iPhone 15 Pro Max (430dp) (430×932) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 12 | 0 | 0 | 2 |
| membersView | 0 | 0 | 8 | 5 | 0 | 0 | 2 |
| attendanceView | 0 | 0 | 8 | 6 | 0 | 0 | 16 |
| dutyHoursView | 0 | 0 | 8 | 6 | 0 | 2 | 2 |
| monthlyReportView | 0 | 0 | 8 | 4 | 0 | 8 | 2 |
| accountsView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| contractView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| interviewView | 0 | 0 | 8 | 3 | 0 | 0 | 2 |
| dataView | 0 | 0 | 8 | 3 | 0 | 0 | 6 |
| systemHealthView | 0 | 0 | 8 | 3 | 0 | 0 | 6 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### iPhone 14 landscape (844×390) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 13 | 0 | 1 | 0 |
| membersView | 0 | 0 | 8 | 10 | 0 | 4 | 28 |
| attendanceView | 0 | 0 | 8 | 9 | 0 | 2 | 0 |
| dutyHoursView | 0 | 0 | 8 | 10 | 0 | 17 | 42 |
| monthlyReportView | 0 | 0 | 8 | 5 | 0 | 8 | 0 |
| accountsView | 0 | 0 | 8 | 11 | 0 | 2 | 38 |
| contractView | 0 | 0 | 8 | 10 | 0 | 7 | 0 |
| interviewView | 0 | 0 | 8 | 9 | 0 | 5 | 0 |
| dataView | 0 | 0 | 8 | 4 | 0 | 0 | 0 |
| systemHealthView | 0 | 0 | 8 | 4 | 0 | 0 | 0 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### Pixel 7 landscape (915×412) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 13 | 0 | 1 | 0 |
| membersView | 0 | 0 | 8 | 10 | 0 | 4 | 48 |
| attendanceView | 0 | 0 | 8 | 9 | 0 | 2 | 0 |
| dutyHoursView | 0 | 0 | 8 | 10 | 0 | 17 | 30 |
| monthlyReportView | 0 | 0 | 8 | 5 | 0 | 8 | 0 |
| accountsView | 0 | 0 | 8 | 11 | 0 | 2 | 38 |
| contractView | 0 | 0 | 8 | 10 | 0 | 7 | 0 |
| interviewView | 0 | 0 | 8 | 9 | 0 | 5 | 0 |
| dataView | 0 | 0 | 8 | 4 | 0 | 0 | 0 |
| systemHealthView | 0 | 0 | 8 | 4 | 0 | 0 | 0 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### iPad mini portrait (744dp) (744×1133) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 13 | 0 | 1 | 0 |
| membersView | 0 | 0 | 8 | 11 | 0 | 4 | 0 |
| attendanceView | 0 | 0 | 8 | 10 | 0 | 2 | 6 |
| dutyHoursView | 0 | 0 | 8 | 11 | 0 | 17 | 0 |
| monthlyReportView | 0 | 0 | 8 | 6 | 0 | 8 | 0 |
| accountsView | 0 | 0 | 8 | 12 | 0 | 2 | 0 |
| contractView | 0 | 0 | 8 | 9 | 0 | 7 | 0 |
| interviewView | 0 | 0 | 8 | 10 | 0 | 5 | 0 |
| dataView | 0 | 0 | 8 | 5 | 0 | 0 | 0 |
| systemHealthView | 0 | 0 | 8 | 5 | 0 | 0 | 0 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### iPad 9.7/10.2 portrait (768dp) (768×1024) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 13 | 0 | 1 | 0 |
| membersView | 0 | 0 | 8 | 10 | 0 | 4 | 28 |
| attendanceView | 0 | 0 | 8 | 9 | 0 | 2 | 26 |
| dutyHoursView | 0 | 0 | 8 | 10 | 0 | 17 | 30 |
| monthlyReportView | 0 | 0 | 8 | 5 | 0 | 8 | 0 |
| accountsView | 0 | 0 | 8 | 11 | 0 | 2 | 70 |
| contractView | 0 | 0 | 8 | 10 | 0 | 7 | 0 |
| interviewView | 0 | 0 | 8 | 9 | 0 | 5 | 0 |
| dataView | 0 | 0 | 8 | 4 | 0 | 0 | 0 |
| systemHealthView | 0 | 0 | 8 | 4 | 0 | 0 | 0 |

- Drawer: opens true • backdrop true • scroll-lock true • focus→sidebar-close • 10 targets (min 48px) • closes true • scroll restored true • Esc true • backdrop-tap false • hamburger ARIA-expanded: ❌ missing
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `block`)
- Console/page errors: 0/0

### iPad Pro 11" landscape (1194dp) (1194×834) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 14 | 0 | 1 | 4 |
| membersView | 0 | 0 | 8 | 9 | 0 | 4 | 28 |
| attendanceView | 0 | 3 | 8 | 16 | 0 | 2 | 1 |
| dutyHoursView | 0 | 10 | 8 | 14 | 4 | 17 | 1 |
| monthlyReportView | 0 | 0 | 8 | 8 | 0 | 8 | 2 |
| accountsView | 0 | 0 | 8 | 11 | 0 | 2 | 70 |
| contractView | 0 | 0 | 8 | 9 | 0 | 7 | 0 |
| interviewView | 0 | 0 | 8 | 10 | 0 | 5 | 0 |
| dataView | 0 | 0 | 8 | 4 | 0 | 0 | 0 |
| systemHealthView | 0 | 0 | 8 | 5 | 0 | 0 | 0 |
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `grid`)
- Console/page errors: 0/0

### iPad Pro 12.9" portrait (1024dp) (1024×1366) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | 0 | 0 | 8 | 14 | 0 | 1 | 2 |
| membersView | 0 | 0 | 8 | 7 | 0 | 4 | 28 |
| attendanceView | 0 | 1 | 8 | 11 | 3 | 2 | 1 |
| dutyHoursView | 0 | 9 | 8 | 11 | 0 | 17 | 42 |
| monthlyReportView | 0 | 1 | 8 | 6 | 0 | 8 | 3 |
| accountsView | 0 | 0 | 8 | 9 | 0 | 2 | 40 |
| contractView | 0 | 0 | 8 | 7 | 0 | 7 | 0 |
| interviewView | 0 | 0 | 8 | 8 | 0 | 5 | 0 |
| dataView | 0 | 0 | 8 | 2 | 0 | 0 | 0 |
| systemHealthView | 0 | 0 | 8 | 6 | 0 | 0 | 0 |
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `grid`)
- Console/page errors: 0/0

### Surface Pro / touch laptop (1368dp) (1368×912) • touch

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | -10 | 0 | 8 | 19 | 0 | 1 | 4 |
| membersView | -10 | 0 | 8 | 9 | 0 | 4 | 28 |
| attendanceView | -10 | 3 | 8 | 13 | 4 | 2 | 1 |
| dutyHoursView | -10 | 10 | 8 | 14 | 4 | 17 | 1 |
| monthlyReportView | -10 | 0 | 8 | 8 | 0 | 8 | 2 |
| accountsView | -10 | 0 | 8 | 11 | 0 | 2 | 56 |
| contractView | -10 | 0 | 8 | 9 | 0 | 7 | 0 |
| interviewView | -10 | 0 | 8 | 10 | 0 | 5 | 0 |
| dataView | -10 | 0 | 8 | 5 | 0 | 0 | 0 |
| systemHealthView | -10 | 0 | 8 | 8 | 0 | 0 | 0 |
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Orientation flip: landscape overflow 0px • lock leak false • restored true (shell `grid`)
- Console/page errors: 0/0

### Small laptop 1280x720 (1280×720) • mouse/trackpad

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | -10 | 0 | 0 | — | 0 | 1 | 0 |
| membersView | -10 | 0 | 8 | — | 0 | 4 | 28 |
| attendanceView | -10 | 0 | 0 | — | 0 | 2 | 1 |
| dutyHoursView | -10 | 0 | 0 | — | 0 | 17 | 42 |
| monthlyReportView | -10 | 0 | 0 | — | 0 | 8 | 0 |
| accountsView | -10 | 0 | 8 | — | 0 | 2 | 41 |
| contractView | -10 | 0 | 0 | — | 0 | 7 | 0 |
| interviewView | -10 | 0 | 0 | — | 0 | 5 | 0 |
| dataView | -10 | 0 | 0 | — | 0 | 0 | 0 |
| systemHealthView | -10 | 0 | 0 | — | 0 | 0 | 0 |
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Console/page errors: 0/0

### Common laptop 1366x768 (1366×768) • mouse/trackpad

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | -10 | 0 | 0 | — | 0 | 1 | 0 |
| membersView | -10 | 0 | 8 | — | 0 | 4 | 48 |
| attendanceView | -10 | 0 | 0 | — | 0 | 2 | 1 |
| dutyHoursView | -10 | 0 | 0 | — | 0 | 17 | 1 |
| monthlyReportView | -10 | 0 | 0 | — | 0 | 8 | 0 |
| accountsView | -10 | 0 | 8 | — | 0 | 2 | 38 |
| contractView | -10 | 0 | 0 | — | 0 | 7 | 0 |
| interviewView | -10 | 0 | 0 | — | 0 | 5 | 0 |
| dataView | -10 | 0 | 0 | — | 0 | 0 | 0 |
| systemHealthView | -10 | 0 | 0 | — | 0 | 0 | 0 |
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Console/page errors: 0/0

### Desktop 1920x1080 (1920×1080) • mouse/trackpad

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | -10 | 0 | 0 | — | 0 | 1 | 0 |
| membersView | -10 | 0 | 0 | — | 0 | 4 | 0 |
| attendanceView | -10 | 0 | 0 | — | 0 | 2 | 0 |
| dutyHoursView | -10 | 0 | 0 | — | 0 | 17 | 0 |
| monthlyReportView | -10 | 0 | 0 | — | 0 | 8 | 0 |
| accountsView | -10 | 0 | 0 | — | 0 | 2 | 0 |
| contractView | -10 | 0 | 0 | — | 0 | 7 | 0 |
| interviewView | -10 | 0 | 0 | — | 0 | 5 | 0 |
| dataView | -10 | 0 | 0 | — | 0 | 0 | 0 |
| systemHealthView | -10 | 0 | 0 | — | 0 | 0 | 0 |
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Console/page errors: 0/0

### Ultra-wide 2560x1080 (2560×1080) • mouse/trackpad

| View | H-overflow | Real clipping | Off-screen nodes | Tap<44 | Tap<24 | Inputs<16px | Scroll containers |
|---|---|---|---|---|---|---|---|
| dashboardView | -10 | 0 | 0 | — | 0 | 1 | 0 |
| membersView | -10 | 0 | 0 | — | 0 | 4 | 0 |
| attendanceView | -10 | 0 | 0 | — | 0 | 2 | 0 |
| dutyHoursView | -10 | 0 | 0 | — | 0 | 17 | 0 |
| monthlyReportView | -10 | 0 | 0 | — | 0 | 8 | 0 |
| accountsView | -10 | 0 | 0 | — | 0 | 2 | 0 |
| contractView | -10 | 0 | 0 | — | 0 | 7 | 0 |
| interviewView | -10 | 0 | 0 | — | 0 | 5 | 0 |
| dataView | -10 | 0 | 0 | — | 0 | 0 | 0 |
| systemHealthView | -10 | 0 | 0 | — | 0 | 0 | 0 |
- Member modal: fits true • close clickable true • closes true • scroll lock released true
- Console/page errors: 0/0
