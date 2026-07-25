# LSO System Stability & Enterprise Operations Upgrade

This package upgrades the Lasallian Symphony Orchestra system to website **v3.0.1**, database target **006_enterprise_operations**, and PWA cache **enterprise-v24**.

For an existing Supabase project:

1. Download a Complete System Backup.
2. Run `LSO_MASTER_MIGRATION_INSTALLER.sql` once in Supabase SQL Editor.
3. Upload every website file to the GitHub Pages publishing root.
4. Open `refresh-lso.html` once.
5. Log in as Administrator and run **System Health**.

For a fresh Supabase project, use `supabase-setup.sql` instead of the migration-only installer.

See `ENTERPRISE_UPGRADE_GUIDE.txt` for the full installation, feature, permission, recovery, and troubleshooting guide.

## Runtime hotfix

This build corrects the Attendance monthly workflow authentication refresh. The module now calls its local `renderEverything()` renderer instead of the undefined `renderAll()` symbol. No database migration is required for this hotfix.
