(() => {
  'use strict';

  const core = window.LSOSystemCore || {};
  const ROLES = core.ROLES || Object.freeze({
    ADMIN: 'Administrator', STAFF: 'Staff Account', MEMBERSHIP: 'Membership', SECRETARY: 'General Secretary', TRAINEE: 'Trainee/Probationary'
  });

  function currentAccount() {
    return window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  }

  function role(account = currentAccount()) {
    return core.role ? core.role(account) : (Object.values(ROLES).includes(account?.role) ? account.role : ROLES.STAFF);
  }

  function canAccessView(viewId, account = currentAccount()) {
    return core.canAccessView ? core.canAccessView(viewId, account) : true;
  }

  function can(action, account = currentAccount()) {
    return core.can ? core.can(action, account) : role(account) === ROLES.ADMIN;
  }

  function canWriteColumn(column, account = currentAccount()) {
    return core.canWriteColumn ? core.canWriteColumn(column, account) : role(account) === ROLES.ADMIN;
  }

  function canUseAttendanceGroup(group, account = currentAccount()) {
    return core.canUseAttendanceGroup ? core.canUseAttendanceGroup(group, account) : role(account) !== ROLES.TRAINEE;
  }

  function defaultAttendanceGroup(account = currentAccount()) {
    return role(account) === ROLES.MEMBERSHIP ? 'Trainee Members' : 'Official Members';
  }

  function defaultView(account = currentAccount()) {
    const allowed = core.PERMISSIONS?.views?.[role(account)] || ['dashboardView'];
    return allowed[0] || 'dashboardView';
  }

  function roleDescription(account = currentAccount()) {
    const value = role(account);
    if (value === ROLES.ADMIN) return 'Administrator • Full Access';
    if (value === ROLES.MEMBERSHIP) return 'Membership • Membership, Reports, Attendance & Duty Hours';
    if (value === ROLES.SECRETARY) return 'General Secretary • Dashboard & Attendance';
    if (value === ROLES.TRAINEE) return 'Trainee/Probationary • Duty Hours Only';
    return 'Staff Account • Dashboard, Members, Attendance Monitoring & Duty Review';
  }

  function deniedMessage(action = '') {
    const value = role();
    if (value === ROLES.SECRETARY) {
      if (['finalizeAttendance', 'unlockAttendance'].includes(action)) return 'General Secretary access can create activities and save Draft attendance. Only the Administrator can finalize or unlock attendance.';
      return 'General Secretary access is limited to the Dashboard and Attendance workspace.';
    }
    if (value === ROLES.MEMBERSHIP) {
      if (action === 'attendanceGroup') return 'Membership attendance access is limited to Trainee and Probationary rosters.';
      if (['finalizeAttendance', 'unlockAttendance'].includes(action)) return 'Membership access can create activities and save Draft attendance for Trainee and Probationary rosters. Only the Administrator can finalize or unlock attendance.';
      return 'Membership access is limited to Dashboard, Members, Member Lookup, Contract, Monthly Report, Attendance, and Duty Hours.';
    }
    if (value === ROLES.TRAINEE) return 'Trainee/Probationary access is limited to personal Duty Hours submission.';
    if (value === ROLES.STAFF) {
      if (action === 'reviewDutyPunches') return 'Staff Accounts may approve or reject pending Trainee/Probationary Time In and Time Out requests.';
      if (action === 'viewDutyRoster') return 'Staff Accounts may view the current Trainee and Probationary Duty Hours rosters and individual progress records.';
      if (['manageEvents','saveDraftAttendance','finalizeAttendance','unlockAttendance'].includes(action)) return 'Staff Attendance access is monitoring-only. Activity and attendance editing are disabled.';
      if (action === 'manageDutyHours') return 'Staff can review Time In and Time Out requests, but cannot manually add, edit, or delete Duty Hours.';
      return 'Staff access is limited to Dashboard, Members, Attendance monitoring, and Duty Hours punch approval.';
    }
    return 'You do not have permission to perform this action.';
  }

  window.LSORoleAccess = {
    ROLES,
    role,
    currentAccount,
    canAccessView,
    can,
    canWriteColumn,
    canUseAttendanceGroup,
    defaultAttendanceGroup,
    defaultView,
    roleDescription,
    deniedMessage,
    viewsForRole: (account = currentAccount()) => [...(core.PERMISSIONS?.views?.[role(account)] || [])],
    permissionManifest: () => JSON.parse(JSON.stringify(core.PERMISSIONS || {}))
  };
})();
