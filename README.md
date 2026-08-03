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

