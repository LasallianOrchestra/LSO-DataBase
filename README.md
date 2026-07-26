# LSO Staff Account Monitoring and Duty Review Update

This package updates the Staff Account role without changing existing records.

Staff can access only Dashboard, Members, Attendance monitoring, and Duty Hours. Staff may approve or reject separate Trainee/Probationary Time In and Time Out requests, but cannot edit members, activities, attendance, or manually manage Duty Hours.

For an existing Supabase project, run `LSO_STAFF_ROLE_MONITOR_DUTY_REVIEW_INSTALL.sql` once before deploying all website files. See `STAFF_ROLE_MONITORING_DUTY_REVIEW_GUIDE.txt` for the exact installation order.


## Default official LSO print template

All system-generated print documents now use portrait orientation by default. The official LSO portrait template repeats on every page. Wide Attendance and Duty Hours tables are reorganized through compact column-aware typography, wrapping, repeated table headers, and automatic portrait pagination. The specialized Membership Contract remains portrait and keeps its official two-page contract template.


## Staff Duty Hours roster visibility fix (v33)

Staff Accounts can now see the current Trainee and Probationary rosters in Duty Hours, select a member, and monitor that member's progress and ledger. Staff still cannot manually add, edit, delete, print, certify, or change Duty Hours requirements. Separate Time In and Time Out approval remains available.

No Supabase migration is required for this display correction because Staff already receives member records and already has server permission to review punches.
