'use strict';

function lsoLegacyAttendanceRefreshV25() {
  if (window.LSOAttendanceMonthWorkspace?.refresh) return window.LSOAttendanceMonthWorkspace.refresh();
  window.dispatchEvent(new CustomEvent('lso:attendance-refresh-request'));
  return undefined;
}
var renderAll = typeof window.renderAll === 'function' ? window.renderAll : lsoLegacyAttendanceRefreshV25;
window.renderAll = renderAll;

(() => {
  'use strict';

  const ROLES = Object.freeze({
    ADMIN: 'Administrator',
    STAFF: 'Staff Account',
    MEMBERSHIP: 'Membership',
    SECRETARY: 'General Secretary',
    TRAINEE: 'Trainee/Probationary'
  });

  const PERMISSIONS = Object.freeze({
    views: Object.freeze({
      [ROLES.ADMIN]: ['dashboardView', 'membersView', 'lookupView', 'contractView', 'monthlyReportView', 'attendanceView', 'dutyHoursView', 'alertsView', 'accountsView', 'systemHealthView', 'dataView'],
      [ROLES.STAFF]: ['dashboardView', 'membersView', 'lookupView', 'attendanceView', 'dutyHoursView', 'alertsView'],
      [ROLES.MEMBERSHIP]: ['dashboardView', 'membersView', 'lookupView', 'contractView', 'monthlyReportView', 'attendanceView', 'dutyHoursView', 'alertsView'],
      [ROLES.SECRETARY]: ['dashboardView', 'membersView', 'lookupView', 'attendanceView', 'dutyHoursView', 'alertsView'],
      [ROLES.TRAINEE]: ['dutyHoursView']
    }),
    actions: Object.freeze({
      manageAccounts: [ROLES.ADMIN],
      manageMembers: [ROLES.ADMIN, ROLES.MEMBERSHIP],
      generateContract: [ROLES.ADMIN, ROLES.MEMBERSHIP],
      editMonthlyReport: [ROLES.ADMIN, ROLES.MEMBERSHIP],
      finalizeMonthlyReport: [ROLES.ADMIN],
      reopenMonthlyReport: [ROLES.ADMIN],
      manageEvents: [ROLES.ADMIN, ROLES.MEMBERSHIP, ROLES.SECRETARY],
      deleteEvents: [ROLES.ADMIN],
      saveDraftAttendance: [ROLES.ADMIN, ROLES.MEMBERSHIP, ROLES.SECRETARY],
      finalizeAttendance: [ROLES.ADMIN],
      unlockAttendance: [ROLES.ADMIN],
      reviewDutyPunches: [ROLES.ADMIN, ROLES.MEMBERSHIP, ROLES.SECRETARY, ROLES.STAFF],
      manageDutyHours: [ROLES.ADMIN, ROLES.MEMBERSHIP],
      manageDutyRequirements: [ROLES.ADMIN, ROLES.MEMBERSHIP],
      certifyDutyHours: [ROLES.ADMIN, ROLES.MEMBERSHIP],
      manageSettings: [ROLES.ADMIN],
      manageInventory: [ROLES.ADMIN],
      manageData: [ROLES.ADMIN],
      manageRecovery: [ROLES.ADMIN],
      viewSystemHealth: [ROLES.ADMIN],
      manageSystemErrors: [ROLES.ADMIN],
      writeActivityLog: [ROLES.ADMIN, ROLES.MEMBERSHIP, ROLES.SECRETARY],
      selfDutyPunch: [ROLES.TRAINEE],
      manageAccessibility: [ROLES.ADMIN, ROLES.STAFF, ROLES.MEMBERSHIP, ROLES.SECRETARY, ROLES.TRAINEE]
    }),
    columns: Object.freeze({
      [ROLES.ADMIN]: ['members', 'events', 'attendance', 'duty_hours', 'monthly_reports', 'monthly_reports_compat', 'instruments', 'settings', 'activity_log'],
      [ROLES.MEMBERSHIP]: ['members', 'events', 'attendance', 'duty_hours', 'monthly_reports', 'monthly_reports_compat', 'settings', 'activity_log'],
      [ROLES.SECRETARY]: ['events', 'attendance', 'activity_log'],
      [ROLES.STAFF]: [],
      [ROLES.TRAINEE]: []
    }),
    attendanceGroups: Object.freeze({
      [ROLES.ADMIN]: ['Official Members', 'Trainee Members', 'Probationary Members'],
      [ROLES.STAFF]: ['Official Members', 'Trainee Members', 'Probationary Members'],
      [ROLES.MEMBERSHIP]: ['Official Members', 'Trainee Members', 'Probationary Members'],
      [ROLES.SECRETARY]: ['Official Members', 'Trainee Members', 'Probationary Members'],
      [ROLES.TRAINEE]: []
    })
  });

  const VERSION = Object.freeze({
    app: '6.7.0',
    build: '2026.08.11-attendance-permission-center.1',
    schemaTarget: '011_open_operational_permissions',
    cache: 'lso-enterprise-v67',
    permissions: 'permissions-manifest-v5-operational-open',
    databaseInstaller: 'LSO_MASTER_MIGRATION_INSTALLER.sql'
  });


  const ERROR_CODES = Object.freeze({
    NETWORK: 'NET-CONNECTION-001',
    SESSION: 'AUTH-SESSION-002',
    SCHEMA: 'DB-SCHEMA-003',
    MIGRATION: 'DB-MIGRATION-004',
    PERMISSION: 'AUTH-PERMISSION-005',
    BACKUP: 'DATA-BACKUP-006',
    RESTORE: 'DATA-RESTORE-007',
    DUTY: 'DUTY-WORKFLOW-008',
    MONTHLY: 'REPORT-MONTHLY-009',
    UNKNOWN: 'SYS-UNEXPECTED-999'
  });

  function role(account) {
    const value = account?.role;
    return Object.values(ROLES).includes(value) ? value : ROLES.STAFF;
  }

  function can(action, account) {
    return (PERMISSIONS.actions[action] || []).includes(role(account));
  }

  function canAccessView(viewId, account) {
    return (PERMISSIONS.views[role(account)] || []).includes(String(viewId || ''));
  }

  function canWriteColumn(column, account) {
    return (PERMISSIONS.columns[role(account)] || []).includes(String(column || ''));
  }

  function canUseAttendanceGroup(group, account) {
    return (PERMISSIONS.attendanceGroups[role(account)] || []).includes(String(group || ''));
  }

  window.LSOSystemCore = Object.freeze({
    VERSION,
    ROLES,
    PERMISSIONS,
    ERROR_CODES,
    role,
    can,
    canAccessView,
    canWriteColumn,
    canUseAttendanceGroup
  });
})();
