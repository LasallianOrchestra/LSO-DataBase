# LSO Dynamic Role & Permission Center V38

Administrator-controlled role landing pages, module visibility, action permissions, Attendance calendar access, and server-derived write permissions.

## Secure installation

1. For a new database, run `supabase-setup.sql` in the Supabase SQL Editor.
2. Run `LSO_SECURE_ADMIN_SETUP.sql` privately. Copy the one-time administrator username and password shown in the result.
3. Run `LSO_DYNAMIC_ROLE_PERMISSION_CENTER_INSTALL.sql` once to install the V38 role and permission migration.
4. Deploy the website files.

For an existing deployment that previously used the fixed `SNA1161` credentials, run `LSO_SECURE_ADMIN_SETUP.sql` once before deploying this patched website. It removes the legacy bootstrap database function, rotates the protected administrator credentials, and invalidates old sessions.

Do not upload SQL Editor results, screenshots of the generated credentials, or an edited copy containing credentials to the public website repository.
