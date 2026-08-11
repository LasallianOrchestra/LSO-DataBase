# LSO Orchestra Management System — V72 Authentication Input Stability Fix

This release repairs Administrator Maintenance Mode with shared-database verification, a hard application gate for non-Administrator accounts, cross-tab synchronization, and a status refresh/preview workflow. All V61 governance features remain included.

# LSO V61 — Operations Governance & Data Integrity

This release adds a system-wide Full Audit Trail, Data Quality Center, account-specific Notification Inbox, adaptive database polling for lower browser load, Role Permission Templates, and Administrator Maintenance Mode. It builds on the V60 end-to-end debugged base and does not require a new Supabase schema migration.

## V61 highlights

- Structured audit entries capture module, actor, role, timestamp, and before/after values for new shared-data changes.
- Data Quality Center detects duplicate, orphaned, incomplete, and invalid records without automatically deleting or rewriting data.
- Notification Inbox supports per-account read, unread, resolved, and archived states while preserving exact-record routing.
- Database polling adapts from active polling to a quieter interval when the server state is unchanged and pauses while the page is hidden.
- Role Permission Templates provide tested working copies that remain editable before the Administrator saves them.
- Administrator Maintenance Mode safely blocks non-Administrator use during controlled upgrades or recovery work.

# LSO V60 — End-to-End Debugged Release

This release completes a full simulated browser regression pass across authentication, account administration, dynamic permissions, members, contracts, Monthly Reports and archives, Attendance, Duty Hours and punch review, notifications, Action Center, System Health, error resolution, recovery, saving/synchronization behavior, PWA delivery, accessibility, and responsive layouts. It also aligns the visible application, System Health, recovery metadata, and PWA cache identifiers with V60. No database schema migration is required.

## V60 verification highlights

- Main end-to-end browser suite: 51 of 51 checks passed.
- Extended administration and workflow suite: 25 of 25 checks passed.
- V59 Attendance lifecycle suite remains included and previously passed 26 of 26 checks.
- No uncaught browser errors or console errors were detected in the simulated runs.
- The deployment package excludes all debug scripts, screenshots, and generated test data.

# LSO V58 — Attendance Lifecycle Workflow

This release rebuilds Attendance around a controlled five-stage lifecycle: Draft, Review, Finalized Archive, Reopened Revision, and Semester Summary. It adds monthly validation, LOA verification, duplicate detection, stable tab navigation, automatic validated archive creation, revision-safe reopening, and responsive cross-device layouts. The V57 semantic save-queue protections remain included.

# LSO Orchestra Management System — V57 Save Queue Stability

This release fixes the repeated **“Saving 1 change…”** cycle across the system without changing any module workflow or database schema.

## Root cause corrected

- Supabase stores shared JSON as `jsonb`, which can return the same object with a different property order. The previous attendance-governance merge compared these objects with ordinary `JSON.stringify`, incorrectly treating equal archive/settings data as a new local change after every poll.
- Shared-storage writes were queued even when a module attempted to save data that was already identical to the stored value.
- A pending marker left by a closed or interrupted browser session could be uploaded before the current server state was checked.
- Settings and Monthly Report compatibility data could request two writes even though both use the same shared settings payload.

## V57 changes

- Uses semantic, property-order-independent comparison for all synchronized JSON data.
- Ignores no-op saves across Members, Attendance, Duty Hours, Monthly Reports, Settings, Accounts-related state, and activity data.
- Clears stale pending markers when local and server data already match.
- Coalesces Settings and Monthly Report compatibility updates into one effective shared payload.
- Verifies the server response before clearing a pending change.
- Preserves a newer edit made while an earlier save is in progress and sends only that newer payload afterward.
- Suppresses duplicate status events and increases retry spacing after real network failures.

No Supabase SQL migration is required.

# LSO Orchestra Management System — V55 Runtime Stability

This release repairs the page-wide lag and browser crashes that appeared as attendance archives and synchronized records grew. It preserves the existing database schema, permissions, workflows, and visual design.

## Root causes corrected

- Finalized attendance archives stored full event and record objects inside shared settings, creating multi-megabyte browser and cloud payloads.
- Collapsed archive sections still rendered every hidden record row, so several revisions could add thousands of DOM elements at page load.
- Cloud updates triggered multiple hidden modules and three Dashboard controllers to rebuild at the same time.
- Archive integrity checks repeatedly serialized complete events, attendance, members, and report datasets.
- Full shared-state objects were cloned after synchronization even though no module consumed that event payload.

## V54 stability changes

- Legacy attendance archives are compacted into indexed dictionaries and compact record rows without deleting archive history.
- New and repaired archives use the compact format automatically.
- Archive records load only when opened and display 75 rows per page.
- Finalized-month reconciliation runs in small idle batches and writes only when data actually changes.
- Hidden modules no longer rebuild on every cloud event; they refresh when opened.
- Cloud settings are compacted before local caching, in-memory use, and upload.
- Browser-storage failures are detected instead of dispatching false update events.
- Lower-power and touch devices automatically reduce animations, blur, shadows, and repeated rendering.
- The PWA uses a new cache version and network-first delivery for updated scripts and styles.

No Supabase SQL migration is required. Deploy on a test branch, sign in, allow the first idle archive-compaction pass to finish, then verify Attendance Archive, Dashboard, Members, Duty Hours, and Accounts before replacing production.

# V53 Attendance Stability and Archive Integrity

- Groups duplicate monthly archive revisions and presents one verified copy per month.
- Keeps older finalized revisions available under a collapsed history section.
- Prevents revision-number rollback when cloud settings arrive out of order.
- Removes Attendance hover movement and stretched month cards.
- Prevents background archive checks from creating repeated cloud saves when nothing changed.
- Keeps user attendance saves and integrity repairs source-aware.

# V52 Attendance, Duty Hours, and Device Performance Repair

- Reconnects finalized live attendance months to their archived original records.
- Normalizes numeric/string event identifiers so archived rows and ratings cannot disappear because of ID type differences.
- Rebuilds incomplete finalized archives after cloud data finishes loading.
- Keeps approved LOA attendance as Excused and outside attendance-rate and absence-streak computations.
- Limits Semester Roster Totals to the current Trainee or Probationary roster; Official Members are excluded.
- Coalesces repeated attendance and duty-hours renders and reduces cloud polling/rendering pressure on touch and lower-power devices.
- Adds a dedicated cross-device performance stylesheet without changing the system color scheme or workflow.

# LSO Orchestra Management System — V51 Targeted Repairs

This release repairs three reported issues without changing the database schema or unrelated workflows:

- Members Overall Record PDF generation no longer uses runtime network fetches for the official LSO header and footer.
- Monthly Report Archive allows authorized deletion of open or locked/finalized archive copies with confirmation and a required reason; the live source report is preserved.
- Attendance LOA reconciliation correctly places older/imported Official Members in the proper phase and updates existing finalized archive snapshots so Excused records, ratings, and absence streaks agree.

- Monthly Report Archive actions are professionally aligned across desktop, tablet, and mobile.
- Trainee and Probationary Duty Hours printouts remove Academic Information, Contact, Duty Status, Period Start, and Entries from the current roster document. Monthly roster printouts also remove Academic Information and Period Start.
- Duty print documents request and print user-entered Prepared By and Authorized By names.

# LSO Orchestra Management System - V49 Members Overall Record

V49 replaces Member Lookup with a unified live record for Official Members, Trainees, and Probationary Members. It reads and updates the same shared member, contract-history, monthly-report, attendance, and duty-hour data used by the source modules.

## V49 highlights

- One search across all three membership phases.
- Unified profile, membership lifecycle, generated contract history, monthly report participation, complete attendance, and duty-hour ledger.
- Permission-aware additions, revisions, and removals without bypassing finalized attendance, finalized monthly reports, or pending duty-punch workflows.
- Newly generated contract PDFs are logged as lightweight metadata in the member record; the PDF file itself remains on the user device.
- Downloadable multi-page PDF overview instead of browser printing.
- Live refresh after local or Supabase-synchronized changes.
- Responsive laptop, tablet, mobile, keyboard, touch, high-contrast, and reduced-motion compatibility.
- No new database table or SQL migration is required. Contract history is stored inside the existing synchronized member record.


## V45 administrator-controlled Duty Hours review

The General Secretary now receives the Duty Hours module and **Approve/reject Duty punches** permission by default. The permission is no longer restricted to a hard-coded role list: an Administrator can assign or remove it for any editable role through System Health → Role & Permission Center. The Administrator role itself, security-critical system administration areas, and linked-member self-service Duty punching remain protected to prevent lockout or identity conflicts.

Run the private `LSO_V45_GENERAL_SECRETARY_DUTY_PERMISSION.sql` patch once in Supabase SQL Editor so the live database accepts and applies the updated permission model.

# LSO Orchestra Management System — V43 Professional Interface

This GitHub-ready release refines the visual presentation into a cleaner, more formal, and consistent administrative interface. It preserves all V42 workflows, roles, permissions, database calls, attendance behavior, monthly reporting functions, and security hardening.

## V43 visual refinements

- Restrained professional Lasallian color system and flatter enterprise surfaces
- Clearer page hierarchy, typography, spacing, buttons, forms, tables, and cards
- More formal Dashboard, Monthly Report, Attendance, Action Center, and System Health presentation
- Consistent laptop, tablet, mobile, keyboard, touch, and reduced-motion behavior
- Isolated `professional-interface-v43.css` override for easy review or rollback

This folder contains the active website/PWA files for the V42 Monthly Filing and Attendance display repair.

## V42 display fixes

- Monthly Filing Information is separated into clear Reporting Period and Required Signatories groups.
- Monthly report inputs use larger readable text, stronger borders, and responsive one-column mobile layouts.
- The manpower summary no longer overflows its panel.
- Attendance no longer uses a fixed-height roster panel that can hide members.
- Official Member, Trainee, and Probationary rosters remain visible inside a dedicated scrollable table.
- Attendance action buttons stay above the roster while the roster itself scrolls vertically and horizontally.
- The member-name column and table header remain visible while scrolling.
- Existing database structure, account roles, permissions, attendance workflow, and report workflow are unchanged.

## Upload through GitHub.com

1. Extract the ZIP on your computer.
2. Open the `LSO-GitHub-Ready-V42` folder.
3. Upload the **contents inside the folder**, not the ZIP file itself.
4. In repository settings, enable GitHub Pages from the branch and root folder containing `index.html`.
5. After deployment, reload the website once. Installed PWA copies will update automatically through the V42 cache version.

The package excludes private SQL setup scripts. This release does not require a database migration and does not change the database schema, role names, or permission definitions.

## V44 cross-device compatibility

The V44 presentation layer keeps the V43 professional interface while adapting navigation, actions, forms, tables, modals, Attendance, Monthly Reports, Action Center, Accounts, and System Health for laptops, tablets, phones, landscape screens, touch input, text zoom, high contrast, reduced motion, and safe-area devices. No database schema, role, permission, or workflow logic is changed.

## Smooth Motion add-on

This package adds `smooth-motion-v1.css`, a presentation-only animation layer for module changes, navigation, cards, dialogs, notifications, tables, and touch feedback. Motion is shortened on small screens and automatically reduced when the operating system's Reduce Motion setting is enabled. No database, permission, role, attendance, report, or account workflow code was changed.


## V48 Smart Notifications

- Attendance risk notifications open the exact member attendance analytics, including the correct Official, Trainee, or Probationary calendar.
- Attendance workflow alerts open the exact event roster.
- Duty Hours reviewer notifications open the exact Time In or Time Out approval card.
- Duty Hours notifications are delivered according to the Administrator-assigned `reviewDutyPunches` permission instead of a fixed role list.
- Trainee/Probationary accounts receive personal notifications when their own Time In or Time Out is approved or rejected.
- Notification data refreshes when the bell is opened and when the app returns to focus, while preserving the existing cloud synchronization workflow.


## V50 Archives, LOA Governance, and Access Distribution

- Members Overall Record PDFs use the official LSO header and footer on every page.
- Every generated or finalized Monthly Report is recorded in an archive; final outputs can be locked, unlocked, viewed, downloaded, or deleted with authorization.
- Every finalized attendance month creates an original archive snapshot for Official, Trainee, and Probationary Members.
- Approved LOA dates are recorded as Excused and excluded from ratings and consecutive-absence signals.
- System Health uses the effective open-error queue so resolved errors do not continue showing an attention alert.
- Notification read state uses stable fingerprints to prevent repeatedly recreated duplicate alerts after Mark as Read.
- Access Control includes role-template copying and bulk module, action, and attendance-group selection before saving.
- No database schema migration is required.


## V55 Attendance Semester State Stability

- Separates Administrator visibility from workflow-state visibility so Finalize/Reopen controls no longer flicker.
- Locks the semester end date after finalization until the semester is explicitly reopened.
- Adds guarded semester finalize/reopen transactions with persistence verification.
- Merges newer attendance-governance entries during shared-database synchronization to prevent stale state regression across devices.
- Adds a responsive, stable action area for laptop, tablet, and mobile browsers.


## V56 Validated Attendance Archive Workflow

- Moves the Attendance Monthly Archive out of the Current Roster finalization panel and into the Attendance Archive view.
- Finalizing a Current Roster month now computes the rating, freezes the member-level records, creates the validated archive, selects it, and opens the Attendance Archive automatically.
- Attendance Archive summaries and individual records are rendered directly from the selected frozen snapshot, preventing mismatches with historical-stage live filters.
- Adds authorized archive deletion. Deleting the current validated copy returns its connected live month to Draft; deleting an older revision leaves the current finalized month unchanged.
- Current Roster remains the only place where monthly and semester finalization actions are shown.
- Archive browsing is read-only, responsive, and separated from the calendar and attendance-entry workspace.
- No Supabase schema migration is required.


## V59 Attendance Debug and Verification

- Displays approved-LOA members in the Current Roster as read-only Excused entries.
- Normalizes numeric and text event/member identifiers so saved attendance cannot disappear or duplicate across legacy data.
- Separates Current and Archive attendance records when reading, summarizing, and saving a roster.
- Makes deletion of the current validated archive return the live month to a true Draft state.
- Removes the per-event save burst during archive deletion; the monthly lifecycle remains the authoritative state.
- Aligns the PWA cache marker with the active service-worker version to prevent the current cache from being removed as stale.
- No Supabase schema migration is required.


## V63 Member Photo & PDF Preview
- Members Overall Record now previews the official PDF before download.
- Member profiles support optimized square face photos stored with the shared member record.
- Photos appear in member directory avatars and the Members Overall Record header.
- Uploaded photos are center-cropped and compressed client-side to a small profile thumbnail (target under about 12 KB) to protect browser/database performance.
- No new Supabase schema or SQL migration is required.


## V64 Member Photo Canvas Compatibility Fix
- Replaced createImageBitmap-based member photo decoding with HTMLImageElement decoding for wider browser compatibility.
- Replaced the nine-argument Canvas drawImage crop with the simpler five-argument scaled draw, preventing overload-resolution failures.
- Added explicit image-dimension validation and a user-friendly fallback error.
- PDF Preview, member photo storage, database flow, permissions, and all unrelated workflows remain unchanged.


## V66 Compact High-Quality Member Profile PDF

- Members Overall Record PDF preview and download now render the member profile picture at a true 2×2 inches (144×144 PDF points).
- The portrait frame and surrounding profile text spacing were adjusted to prevent overlap.
- No database, workflow, permission, or member-data logic was changed.


## V66 profile layout and portrait quality

- Keeps the Overall Record portrait at a true 2×2 inches in PDF output.
- Uses member details beside the portrait to remove excessive blank space.
- Shortens decorative divider rules for a cleaner official-document layout.
- Stores newly uploaded portraits at up to 512×512 JPEG with adaptive high-quality compression (roughly up to 90 KB) instead of the previous 128×128 thumbnail.
- Existing low-resolution photos must be re-uploaded from the original image to gain the higher-quality source; upscaling cannot restore detail already discarded in older thumbnails.

## V68 Member Overall Record PDF Table Layout

- Repairs Attendance activity creation so **+ New Activity** and **Create on Selected Date** are governed by the currently selected month, not by a previously selected finalized activity.
- Adds a submit-time workflow check so an activity cannot be accidentally created inside an In Review or Finalized month.
- Removes hard-coded Administrator-only presentation from Attendance and Monthly Report workflow controls; these controls now follow the saved dynamic action permissions while their workflow state still controls when they are visible.
- Refreshes Role Management descriptions to match Members Overall Record, profile photos/PDF preview, three-phase Monthly Reports and archive, Attendance Review/Finalize/Archive/Reopen, Duty Hours punches/archives, Action Center, and current governance features.
- Adds **Grant Full Operational Access** and **Clear Operational Access** working-copy actions. Security-owner controls remain protected from delegation.
- Adds module/action dependency validation before a role profile can be saved.
- Requires the separate V67 Supabase permission patch so the live permission center accepts the current operational permission model without legacy role-name restrictions.
- Updates application/PWA/cache metadata to V68 for the Members Overall Record PDF layout refresh.

## V69 Platform Operations Upgrade
- Advanced Dashboard Analytics with operational attendance, duty, membership-stage, and Monthly Report summaries.
- Data Quality workflow with Active/Resolved history and Administrator resolution notes.
- Per-account notification preferences plus Administrator role defaults.
- Lightweight database metadata polling, server-side collection pagination API, JSONB/normalized indexes, and conflict-aware writes.
- Detailed synchronization status with pending changes, last sync, and conflict resolution controls.
- Centralized Document Center for member overviews, contract history, finalized attendance, Monthly Reports, and Duty records.
- Mobile sticky action improvements and contained high-volume data tables.
- Runtime integrity checker, Staging/Production badge, and searchable Help Center.
- Requires `LSO_V69_PLATFORM_OPERATIONS_UPGRADE.sql` in Supabase to enable server pagination, conflict protection, database indexes, and shared notification preferences.

### V69 deployment requirement
Run `LSO_V69_PLATFORM_OPERATIONS_UPGRADE.sql` privately in the Supabase SQL Editor after deploying the V69 website. The SQL enables conflict-aware writes, metadata-only polling, server-side collection pagination, database indexes, shared notification preferences, and Document Center permission support. Do not upload the SQL file to the public GitHub Pages repository.

For future pre-deployment checks, run `node predeploy-integrity-v69.js` from the website folder. It exits with a non-zero status if a structural deployment check fails.

## V71 Authentication Clean Start Fix
- Expired or legacy browser sessions are cleared silently instead of leaving a persistent red login warning.
- Browser sessions are build-scoped so a token from an older application release is not automatically resumed after a major deployment.
- Invalid-session recovery is deduplicated so several failed background requests cannot repeatedly reset the login screen.
- Delayed invalid-session responses from an older token cannot disconnect a newly authenticated session.
- Critical authentication, cloud, system-error, PWA, manifest, and core script cache-busting URLs now use the V71 deployment marker.
- The pre-deployment integrity checker now validates V71 application/cache identity while retaining the V69 database schema target.


## V72 Authentication Input Stability Fix
- Prevents delayed expired-session events from repeatedly resetting the Login form while a user is typing.
- Explicitly restores Login and Register form interactivity after authentication cleanup, including removing stale busy/inert/pointer-event states.
- Ignores session-invalid broadcasts once no active/stored session exists.
- The cloud layer broadcasts session invalidation only for the currently connected token.
- Hides maintenance overlays when returning to the unauthenticated Login screen so they cannot intercept pointer or keyboard interaction.
- Updates application, manifest, service worker, and critical authentication cache markers to V72.
