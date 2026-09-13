/* Browser-side mock of the Supabase JS SDK (the CDN is unreachable in this sandbox).
   It implements only what LSO's cloud-staff layer calls, so the REAL app code paths
   (login, authorize, state load, render) execute against synthetic data. */
function buildShim(seed) {
  const SEED = seed;
  return `
(function () {
  var SEED = ${JSON.stringify(seed)};
  window.__mockRpcLog = [];
  function state() { return JSON.parse(JSON.stringify(SEED.state)); }
  function accounts() { return JSON.parse(JSON.stringify(SEED.accounts)); }
  function rpcData(name, params) {
    window.__mockRpcLog.push(name);
    switch (name) {
      case 'lso_ping': return true;
      case 'lso_login': return { ok: true, token: 'mock-token-administrator', account: accounts()[0] };
      case 'lso_resume_session': return { ok: true, token: params && params.p_token, account: accounts()[0] };
      case 'lso_logout': return { ok: true };
      case 'lso_get_state': return state();
      case 'lso_get_state_meta_v69': return { columnVersions: { members: 3, events: 3, instruments: 3, activity_log: 3, settings: 3, duty_hours: 3, monthly_reports_compat: 3 }, updatedAt: new Date().toISOString(), sizeBytes: 120000 };
      case 'lso_v69_capabilities': return { ok: true, collections: true, notifications: true, permissions: true, recovery: true, audit: true, dataQuality: true, maintenance: true, version: 82 };
      case 'lso_list_accounts': return accounts();
      case 'lso_save_accounts': return { ok: true, accounts: accounts() };
      case 'lso_delete_account': return { ok: true };
      case 'lso_register_account': return { ok: true, account: accounts()[4] };
      case 'lso_get_permission_center': return { ok: true, roles: [], templates: [], permissions: {}, matrix: [], version: 39 };
      case 'lso_save_role_permissions': return { ok: true };
      case 'lso_reset_role_permissions': return { ok: true };
      case 'lso_system_health': return { ok: true, healthy: true, checks: [], version: 'V74', issues: [], lastVerifiedAt: new Date().toISOString() };
      case 'lso_list_system_errors': return [];
      case 'lso_log_system_error': return { ok: true };
      case 'lso_resolve_system_error': return { ok: true };
      case 'lso_list_recovery_points': return [];
      case 'lso_create_recovery_point': return { ok: true, id: 'rp-mock' };
      case 'lso_delete_recovery_point': return { ok: true };
      case 'lso_restore_recovery_point': return { ok: true };
      case 'lso_get_collection_page_v69': return { items: [], total: 0, page: 1, pageSize: 50 };
      case 'lso_get_notification_preferences_v69': return {};
      case 'lso_save_notification_preferences_v69': return { ok: true };
      case 'lso_save_role_notification_preferences_v69': return { ok: true };
      case 'lso_update_state': case 'lso_update_state_v69': case 'lso_replace_state': return { ok: true, state: state() };
      case 'lso_submit_duty_entry': return { ok: true };
      case 'lso_review_duty_entry': case 'lso_review_duty_punch': return { ok: true };
      case 'lso_duty_time_in': case 'lso_duty_time_out': return { ok: true };
      case 'lso_sync_health_v82': return { ok: true, synchronized: true };
      default: return { ok: true };
    }
  }
  function builder() {
    var self = {
      select: function () { return self; }, insert: function () { return self; }, update: function () { return self; },
      upsert: function () { return self; }, delete: function () { return self; }, eq: function () { return self; },
      neq: function () { return self; }, gt: function () { return self; }, gte: function () { return self; },
      lt: function () { return self; }, lte: function () { return self; }, order: function () { return self; },
      limit: function () { return self; }, range: function () { return self; }, single: function () { return self; },
      maybeSingle: function () { return self; }, filter: function () { return self; }, ilike: function () { return self; },
      in: function () { return self; }, is: function () { return self; }, then: function (res, rej) { return Promise.resolve({ data: [], error: null, count: 0 }).then(res, rej); },
      catch: function (rej) { return Promise.resolve({ data: [], error: null }).catch(rej); }
    };
    return self;
  }
  function makeClient() {
    return {
      rpc: function (name, params) {
        try { return Promise.resolve({ data: rpcData(name, params), error: null }); }
        catch (e) { return Promise.resolve({ data: null, error: { message: String(e && e.message || e) } }); }
      },
      from: function () { return builder(); },
      auth: {
        getSession: function () { return Promise.resolve({ data: { session: null }, error: null }); },
        onAuthStateChange: function () { return { data: { subscription: { unsubscribe: function () {} } } }; },
        signOut: function () { return Promise.resolve({ error: null }); }
      },
      channel: function () {
        var ch = {
          on: function () { return ch; }, subscribe: function (cb) { if (typeof cb === 'function') setTimeout(function () { cb('SUBSCRIBED'); }, 0); return ch; },
          unsubscribe: function () { return ch; }, send: function () { return ch; }, track: function () { return ch; },
          untrack: function () { return ch; }
        };
        return ch;
      },
      removeChannel: function () { return Promise.resolve('ok'); },
      removeAllChannels: function () { return Promise.resolve('ok'); }
    };
  }
  window.supabase = { createClient: makeClient, createSupabaseClient: makeClient };
})();
`;
}
module.exports = { buildShim };
