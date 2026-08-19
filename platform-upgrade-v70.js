(() => {
  'use strict';
  const VERSION = '8.0.0';
  const SETTINGS_KEY = 'lso_system_settings_v2';
  const MEMBER_KEY = 'lso_member_database_v1';
  const EVENTS_KEY = 'lso_events_v2';
  const ATTENDANCE_KEY = 'lso_attendance_v2';
  const DUTY_KEY = 'lso_duty_hours_v1';
  const MONTHLY_KEY = 'lso_monthly_reports_v1';
  const QUALITY_FIELD = 'dataQualityWorkflowV69';
  const ENV_FIELD = 'deploymentEnvironmentV69';
  const PREF_BUCKETS = ['Attendance','Duty Hours','Monthly Report','Accounts','Events','Data Quality','System Administration','Members','Contracts','System Administration'];
  const $ = (id) => document.getElementById(id);
  const safe = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const clone = (v) => { try { return JSON.parse(JSON.stringify(v)); } catch { return v; } };
  const normalize = (v) => String(v ?? '').trim().toLowerCase().replace(/\s+/g,' ');
  const readRaw = (key) => { try { return window.LSOStorage?.getItem?.(key) ?? localStorage.getItem(key); } catch { return null; } };
  const readJson = (key, fallback) => { try { const v = JSON.parse(readRaw(key) || 'null'); return v ?? fallback; } catch { return fallback; } };
  const writeJson = (key, value) => { const raw=JSON.stringify(value); if(window.LSOStorage?.setItem) return window.LSOStorage.setItem(key,raw)!==false; try{localStorage.setItem(key,raw);return true;}catch{return false;} };
  const account = () => window.LSOAuth?.getActiveAccount?.() || window.LSOCurrentAccount || null;
  const isAdmin = () => account()?.role === 'Administrator';
  const toast = (m,e=false) => window.LSOApp?.showToast?.(m,e);
  const dateTime = (value) => { const d = value ? new Date(value) : null; return d && !Number.isNaN(d.getTime()) ? new Intl.DateTimeFormat('en-PH',{dateStyle:'medium',timeStyle:'short',timeZone:'Asia/Manila'}).format(d) : '—'; };
  const monthLabel = (key) => { const m=String(key||'').match(/^(\d{4})-(\d{2})$/); if(!m)return String(key||'—'); return new Intl.DateTimeFormat('en-PH',{month:'short',year:'numeric'}).format(new Date(Number(m[1]),Number(m[2])-1,1)); };
  const uid = (prefix='v69') => window.crypto?.randomUUID?.() || `${prefix}-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    let analyticsTimer = 0;
    let lastSyncEventAt = '';
  let accountPrefs = {};
  let rolePrefs = {};
  let preferenceLoaded = false;
  let qualityObserver = null;

  function currentSettings() { const v = readJson(SETTINGS_KEY, {}); return v && typeof v === 'object' && !Array.isArray(v) ? v : {}; }
  function updateSettings(patch, source='v69-settings') {
    if (!isAdmin()) return false;
    const next = { ...currentSettings(), ...patch };
    const ok = writeJson(SETTINGS_KEY, next);
    if (ok) window.dispatchEvent(new CustomEvent('lso:operations-changed',{detail:{key:SETTINGS_KEY,source}}));
    return ok;
  }

  // ---------- Dashboard analytics ----------
  function periodForMember(member) {
    const today = new Date().toISOString().slice(0,10);
    if (member.memberStatus && normalize(member.memberStatus).includes('loa')) return 'LOA';
    if (member.regularMemberDate && member.regularMemberDate <= today) return 'Official';
    if (!member.probationarySkipped && member.probationaryStartDate && member.probationaryStartDate <= today) return 'Probationary';
    return 'Trainee';
  }
  function attendanceMonthRates(events, rows) {
    const eventMap = new Map(events.map(e => [String(e.id), e]));
    const buckets = new Map();
    rows.forEach(r => {
      const event = eventMap.get(String(r.eventId)); const month = String(event?.date || '').slice(0,7); if (!/^\d{4}-\d{2}$/.test(month)) return;
      if (!['Present','Late','Absent'].includes(r.status)) return;
      const b = buckets.get(month) || {earned:0,total:0}; b.total += 1; b.earned += r.status === 'Present' ? 1 : r.status === 'Late' ? .75 : 0; buckets.set(month,b);
    });
    return [...buckets.entries()].sort((a,b)=>a[0].localeCompare(b[0])).slice(-6).map(([month,b]) => ({month,rate:b.total?Math.round(b.earned/b.total*100):null}));
  }
  function renderDashboardAnalytics() {
    const host = $('v69DashboardAnalytics'); if (!host || !document.getElementById('dashboardView')?.classList.contains('active')) return;
    const members = readJson(MEMBER_KEY, []), events = readJson(EVENTS_KEY, []), attendance = readJson(ATTENDANCE_KEY, []), duty = readJson(DUTY_KEY, {}), monthly = readJson(MONTHLY_KEY, {});
    const dutyEntries = Array.isArray(duty?.entries) ? duty.entries : [];
    const pendingDuty = dutyEntries.filter(e => ['Pending','Pending Time In','Pending Time Out'].includes(e.approvalStatus) || e.timeInApprovalStatus === 'Pending' || e.timeOutApprovalStatus === 'Pending').length;
    const reports = monthly?.reports && typeof monthly.reports === 'object' ? Object.values(monthly.reports) : [];
    const finalizedReports = reports.filter(r => r?.workflowStatus === 'Finalized').length;
    const activeMembers = members.filter(m => normalize(m.memberStatus || 'active') !== 'inactive');
    const stages = activeMembers.reduce((out,m)=>{ const p=periodForMember(m); out[p]=(out[p]||0)+1; return out; },{});
    const lowThreshold = Number(currentSettings().attendanceThreshold || 75);
    const memberRates = new Map(); attendance.forEach(r=>{ if(!['Present','Late','Absent'].includes(r.status))return; const id=String(r.memberId); const b=memberRates.get(id)||{e:0,t:0}; b.t++; b.e+=r.status==='Present'?1:r.status==='Late'?.75:0; memberRates.set(id,b); });
    const lowAttendance = [...memberRates.values()].filter(b=>b.t && Math.round(b.e/b.t*100)<lowThreshold).length;
    const trends = attendanceMonthRates(events, attendance);
    host.innerHTML = `<article class="panel v69-analytics-panel"><div class="v69-analytics-header"><div><p class="eyebrow">Management Analytics</p><h3>Operational Snapshot</h3><p class="panel-subtitle">Live summaries from existing validated records. Cards update only when source data changes or the Dashboard is opened.</p></div><small>${safe(new Intl.DateTimeFormat('en-PH',{dateStyle:'medium',timeStyle:'short'}).format(new Date()))}</small></div><div class="v69-analytics-grid"><button class="v69-analytics-card" data-v69-jump="membersView" type="button"><span>Active Membership</span><strong>${activeMembers.length}</strong><small>${stages.Official||0} official • ${stages.Trainee||0} trainee • ${stages.Probationary||0} probationary${stages.LOA?` • ${stages.LOA} LOA`:''}</small></button><button class="v69-analytics-card" data-v69-jump="attendanceView" type="button"><span>Low Attendance</span><strong>${lowAttendance}</strong><small>Below ${lowThreshold}% based on rated Present/Late/Absent rows</small></button><button class="v69-analytics-card" data-v69-jump="dutyHoursView" type="button"><span>Pending Duty Punches</span><strong>${pendingDuty}</strong><small>Time In/Out requests still requiring review</small></button><button class="v69-analytics-card" data-v69-jump="monthlyReportView" type="button"><span>Finalized Monthly Reports</span><strong>${finalizedReports}</strong><small>${reports.length} report month${reports.length===1?'':'s'} currently stored</small></button></div><div class="v69-trend"><div class="v69-analytics-header"><div><strong>Attendance trend</strong><small>Last six months with rated records</small></div></div><div class="v69-trend-bars">${trends.length?trends.map(t=>`<div class="v69-trend-item"><div class="v69-trend-bar" style="height:${Math.max(4,Number(t.rate)||0)}px" title="${safe(monthLabel(t.month))}: ${t.rate}%"></div><strong>${t.rate}%</strong><small>${safe(t.month.slice(5))}/${safe(t.month.slice(2,4))}</small></div>`).join(''):'<div class="v69-empty" style="grid-column:1/-1">No rated attendance trend is available yet.</div>'}</div></div></article>`;
  }
  function scheduleAnalytics() { clearTimeout(analyticsTimer); analyticsTimer=setTimeout(renderDashboardAnalytics,120); }

  // ---------- Notification preferences ----------
  function notificationBucket(notification){ const c=normalize(notification?.category); const a=normalize(notification?.actionType); if(c.includes('attendance')||a.includes('attendance'))return'Attendance'; if(c.includes('duty')||a.includes('duty'))return'Duty Hours'; if(c.includes('monthly')||a.includes('monthly'))return'Monthly Report'; if(c.includes('account')||a==='accounts')return'Accounts'; if(c.includes('event')||a==='event')return'Events'; if(c.includes('data quality')||a==='data-quality')return'Data Quality'; if(c.includes('health')||a==='system-health')return'System Administration'; if(c.includes('member')||a==='member')return'Members'; if(c.includes('contract'))return'Contracts'; return'System Administration'; }
  function migratePreferenceNames(prefs={}){const next={...(prefs||{})};const legacyKey=['System','Health'].join(' ');if(Object.prototype.hasOwnProperty.call(next,legacyKey)&&!Object.prototype.hasOwnProperty.call(next,'System Administration'))next['System Administration']=next[legacyKey];delete next[legacyKey];return next;}
  function mergedPrefs(){ const base={}; PREF_BUCKETS.forEach(k=>base[k]=true); Object.assign(base,migratePreferenceNames(rolePrefs),migratePreferenceNames(accountPrefs)); return base; }
  function allows(notification){ const priority=normalize(notification?.priority||notification?.severity); if(priority==='critical'||priority==='error')return true; return mergedPrefs()[notificationBucket(notification)] !== false; }
  async function loadNotificationPreferences(){
    const fallbackKey=`lso_v69_notification_prefs_${normalize(account()?.username||'anonymous')}`; let payload=null;
    try { payload=await window.LSOCloud?.getNotificationPreferences?.(); } catch {}
    if(payload){accountPrefs=migratePreferenceNames(payload.accountPreferences||{});rolePrefs=migratePreferenceNames(payload.rolePreferences||{});preferenceLoaded=true;}
    else {try{accountPrefs=JSON.parse(localStorage.getItem(fallbackKey)||'{}');}catch{accountPrefs={};}rolePrefs={};preferenceLoaded=true;}
    renderNotificationPreferences(); window.LSODashboardNotifications?.renderNotifications?.(); window.LSONotificationInbox?.render?.();
  }
  function prefOptions(prefs,prefix){return PREF_BUCKETS.map(k=>`<label class="v69-pref-option"><input type="checkbox" data-v69-pref="${safe(k)}" data-pref-scope="${prefix}" ${prefs?.[k]!==false?'checked':''}/><span>${safe(k)}</span></label>`).join('');}
  function renderNotificationPreferences(){ if(!$('v69AccountNotificationPrefs'))return; $('v69AccountNotificationPrefs').innerHTML=prefOptions(accountPrefs,'account'); $('v69RoleNotificationPrefs').innerHTML=prefOptions(rolePrefs,'role'); $('v69NotificationPrefStatus').textContent=preferenceLoaded?'Preferences loaded. Critical system notices remain visible in System Administration.':'Loading preferences…'; }
  function collectPrefs(scope){const out={};document.querySelectorAll(`[data-pref-scope="${scope}"]`).forEach(i=>out[i.dataset.v69Pref]=i.checked);return out;}
  async function saveAccountPrefs(){ const next=collectPrefs('account'); const key=`lso_v69_notification_prefs_${normalize(account()?.username||'anonymous')}`; try{const result=await window.LSOCloud?.saveNotificationPreferences?.(next); if(result)accountPrefs=result.accountPreferences||next; else throw new Error('fallback');}catch{accountPrefs=next;try{localStorage.setItem(key,JSON.stringify(next));}catch{}} renderNotificationPreferences();window.LSODashboardNotifications?.renderNotifications?.();window.LSONotificationInbox?.render?.();toast('Notification preferences saved.');}
  async function saveRolePrefs(){ if(!isAdmin())return; const role=$('v69NotificationRole')?.value||'Staff Account',next=collectPrefs('role'); try{const result=await window.LSOCloud?.saveRoleNotificationPreferences?.(role,next);rolePrefs=migratePreferenceNames(result?.rolePreferences||next);toast(`${role} notification defaults saved.`);}catch(e){toast(e.message||'Role notification defaults could not be saved.',true);}renderNotificationPreferences();}

  window.LSONotificationPreferencesV69={allows,bucket:notificationBucket,reload:loadNotificationPreferences};

  // ---------- Data Quality resolution workflow ----------
  function qualityState(){const value=currentSettings()[QUALITY_FIELD];return value&&typeof value==='object'?value:{version:1,resolved:{}};}
  function qualityFingerprint(card){const title=card.querySelector('strong')?.textContent||'';const detail=card.querySelector('small')?.textContent||'';const action=card.querySelector('[data-quality-action]')?.dataset.qualityAction||'';const target=card.querySelector('[data-quality-target]')?.dataset.qualityTarget||'';return normalize(`${title}|${detail}|${action}|${target}`);}
  function enhanceQualityCards(){ const host=$('dataQualityIssues');if(!host||!isAdmin())return; const workflow=$('dataQualityWorkflowStatus')?.value||'active',state=qualityState();
    if(workflow==='resolved'){const rows=Object.values(state.resolved||{}).sort((a,b)=>String(b.resolvedAt||'').localeCompare(String(a.resolvedAt||'')));const html=rows.length?rows.map(r=>`<article class="v61-quality-item severity-info"><span class="v69-quality-workflow-badge is-resolved">Resolved</span><div><strong>${safe(r.title)}</strong><small>${safe(r.module)} • ${safe(r.detail)}</small><small>Resolved ${safe(dateTime(r.resolvedAt))} by ${safe(r.resolvedBy||'Administrator')} • ${safe(r.reason||'No reason recorded')}</small></div></article>`).join(''):'<div class="v61-empty"><strong>No resolved Data Quality findings.</strong><small>Resolved findings remain here for cross-checking.</small></div>';if(host.innerHTML!==html)host.innerHTML=html;return;}
    [...host.querySelectorAll('.v61-quality-item')].forEach(card=>{const fp=qualityFingerprint(card); const resolved=state.resolved?.[fp]; if(resolved&&workflow==='active'){card.remove();return;} if(card.querySelector('[data-v69-quality-resolve]'))return; const title=card.querySelector('strong')?.textContent||'Data Quality issue',detail=card.querySelector('small')?.textContent||'',module=detail.split(' • ')[0]||'Data Quality'; const actions=card.querySelector('button')?.parentElement||card; const wrap=document.createElement('div');wrap.className='v69-quality-actions'; const existing=card.querySelector('button');if(existing)wrap.appendChild(existing);const btn=document.createElement('button');btn.type='button';btn.className='button button-secondary';btn.dataset.v69QualityResolve=fp;btn.dataset.qualityTitle=title;btn.dataset.qualityDetail=detail;btn.dataset.qualityModule=module;btn.textContent='Resolve';wrap.appendChild(btn);card.appendChild(wrap);});
    if(workflow==='all'){
      const resolvedRows=Object.values(state.resolved||{}).sort((a,b)=>String(b.resolvedAt||'').localeCompare(String(a.resolvedAt||'')));
      if(resolvedRows.length && !host.querySelector('[data-v69-resolved-history]')){
        const section=document.createElement('section'); section.dataset.v69ResolvedHistory='true'; section.className='v69-quality-resolved-history';
        section.innerHTML=`<div class="v69-quality-history-title"><strong>Resolved History</strong><small>${resolvedRows.length} retained cross-check record${resolvedRows.length===1?'':'s'}</small></div>${resolvedRows.map(r=>`<article class="v61-quality-item severity-info"><span class="v69-quality-workflow-badge is-resolved">Resolved</span><div><strong>${safe(r.title)}</strong><small>${safe(r.module)} • ${safe(r.detail)}</small><small>Resolved ${safe(dateTime(r.resolvedAt))} by ${safe(r.resolvedBy||'Administrator')} • ${safe(r.reason||'No reason recorded')}</small></div></article>`).join('')}`;
        host.appendChild(section);
      }
    }
  }
  function resolveQuality(button){ if(!isAdmin())return; const reason=prompt('Enter the resolution or cross-check note for this Data Quality finding:');if(reason===null)return;const state=qualityState();state.resolved=state.resolved||{};state.resolved[button.dataset.v69QualityResolve]={id:uid('dq'),title:button.dataset.qualityTitle,detail:button.dataset.qualityDetail,module:button.dataset.qualityModule,resolvedAt:new Date().toISOString(),resolvedBy:account()?.username||'Administrator',reason:reason.trim()||'Reviewed and resolved'};state.updatedAt=new Date().toISOString();if(updateSettings({[QUALITY_FIELD]:state},'data-quality-resolve')){toast('Data Quality finding moved to resolved history.');setTimeout(()=>window.LSOOperationsGovernanceV61?.renderDataQuality?.(true),60);}}

  // ---------- Environment & integrity ----------
  function deploymentEnvironment(){const configured=currentSettings()[ENV_FIELD];if(configured==='Staging'||configured==='Production')return configured;return /localhost|127\.0\.0\.1|staging|test/i.test(location.hostname)?'Staging':'Production';}
  function renderEnvironment(){const env=deploymentEnvironment(),badge=$('v69EnvironmentBadge');if(badge){badge.textContent=env.toUpperCase();badge.dataset.env=env;}if($('v69EnvironmentSelect')){$('v69EnvironmentSelect').value=env;$('v69EnvironmentSelect').disabled=!isAdmin();}if($('v69DeploymentVersion'))$('v69DeploymentVersion').textContent=`LSO ${window.LSOSystemCore?.VERSION?.app||VERSION} • ${window.LSOSystemCore?.VERSION?.schemaTarget||'database schema'}`;}
  async function runIntegrityCheck(){const host=$('v69IntegrityResults');if(!host)return;const btn=$('v69RunIntegrityCheck');if(btn){btn.disabled=true;btn.textContent='Checking…';}const checks=[];const push=(name,ok,detail)=>checks.push({name,ok:Boolean(ok),detail});try{
    push('Authenticated session',Boolean(account()),account()?.role||'No account');
    push('Shared database connector',Boolean(window.LSOCloud?.client&&window.LSOCloud?.getSessionToken?.()),window.LSOCloud?.isOnline?.()?'Connected':'Connector loaded');
    push('Role permission engine',Boolean(window.LSORoleAccess?.canAccessView),'Dynamic role access available');
    push('Attendance lifecycle',Boolean(window.LSOAttendanceGovernance?.finalizeMonth),'Review / Finalize / Archive controller loaded');
    push('Member records',Boolean(window.LSOApp?.openRecord),'Member directory and profile editor loaded');
    push('Monthly Report',Boolean(window.LSOMonthlyReport?.getArchives),'Monthly archive controller loaded');
    push('Duty Hours',Boolean(window.LSODutyHours?.getData),'Duty ledger controller loaded');
    const duplicates=[...document.querySelectorAll('[id]')].reduce((m,n)=>(m.set(n.id,(m.get(n.id)||0)+1),m),new Map());push('DOM identifiers',[...duplicates.values()].every(n=>n===1),`${duplicates.size} unique IDs`);
    const capabilities=await window.LSOCloud?.getV69Capabilities?.();push('V69 database optimization',Boolean(capabilities?.installed),capabilities?.installed?'Server paging, revisions, indexes and preferences available':'Run the V69 SQL patch');
    const permissionPayload=await window.LSOCloud?.getRolePermissionCenter?.();const nativeV82=Number(permissionPayload?.schemaVersion||0)>=13||String(permissionPayload?.permissionModel||'').toLowerCase()==='v82';push('V82 all-role permission synchronization',nativeV82,nativeV82?'Interview + derived write columns are server-native':'Run LSO_V82_ROLE_SYNC_SUPABASE_PATCH.sql');
    const reachable=await window.LSOCloud?.checkConnection?.({quiet:true});push('Session-aware database health',Boolean(reachable),reachable?'Authenticated shared-state endpoint reachable':'Shared-state endpoint requires attention');
    const snap=window.LSOCloud?.getSyncSnapshot?.()||{};push('Save queue',!(snap.pending||[]).length,`${(snap.pending||[]).length} pending`);push('Sync conflicts',!(snap.conflicts||[]).length,`${(snap.conflicts||[]).length} unresolved`);
  }catch(e){push('Integrity runner',false,e.message||'Unexpected check error');}
    host.innerHTML=checks.map(c=>`<div class="v69-integrity-row" data-ok="${c.ok}"><span>${safe(c.name)}<small> • ${safe(c.detail)}</small></span><strong>${c.ok?'PASS':'ACTION'}</strong></div>`).join('');if(btn){btn.disabled=false;btn.textContent='Run Integrity Check';}return checks;}
  async function refreshCapabilities(){const caps=await window.LSOCloud?.getV69Capabilities?.();if($('v69DatabaseOptimizationStatus'))$('v69DatabaseOptimizationStatus').textContent=caps?.installed?'V69 Ready':'SQL Patch Required';}

  // ---------- Sync status & conflicts ----------
  function renderSyncStatus(){const snap=window.LSOCloud?.getSyncSnapshot?.()||{};const pending=snap.pending||[],blocked=snap.blockedPending||[],conflicts=snap.conflicts||[];const state=String(snap.connectionState||'');const connectionLabel=state==='reconnecting'?'Reconnecting…':state==='checking'?'Checking…':snap.online?'Online':'Offline';if($('v69SyncConnection'))$('v69SyncConnection').textContent=connectionLabel;if($('v69SyncPending'))$('v69SyncPending').textContent=blocked.length?`${pending.length} change${pending.length===1?'':'s'} • ${blocked.length} awaiting permission`:`${pending.length} change${pending.length===1?'':'s'}`;if($('v69SyncLast'))$('v69SyncLast').textContent=snap.lastSuccessfulSyncAt?dateTime(snap.lastSuccessfulSyncAt):'Not yet';if($('v69SyncConflicts'))$('v69SyncConflicts').textContent=conflicts.length?`${conflicts.length} require review`:'None';if($('v69DeploymentLastSync'))$('v69DeploymentLastSync').textContent=snap.lastSuccessfulSyncAt?dateTime(snap.lastSuccessfulSyncAt):'Not yet synchronized';const list=$('v69ConflictList');if(list)list.innerHTML=conflicts.map(c=>`<article class="v69-conflict"><strong>${safe(String(c.column||'record').replace(/_/g,' '))} changed on another device</strong><small>Detected ${safe(dateTime(c.detectedAt))}. Choose the shared version or intentionally keep this device's pending version.</small><div class="inline-actions"><button class="button button-secondary" data-v69-conflict="${safe(c.column)}" data-resolution="remote" type="button">Use Shared Version</button><button class="button button-primary" data-v69-conflict="${safe(c.column)}" data-resolution="local" type="button">Keep My Changes</button></div></article>`).join('');}
  function toggleSync(open){const p=$('v69SyncPopover'),t=$('v69SyncTrigger');if(!p)return;const next=open??p.classList.contains('hidden');p.classList.toggle('hidden',!next);t?.setAttribute('aria-expanded',String(next));if(next)renderSyncStatus();}

  function toggleNotificationSettings(open) {
    const modal = $('notificationSettingsModal');
    if (!modal) return;
    const next = open ?? modal.classList.contains('hidden');
    modal.classList.toggle('hidden', !next);
    modal.setAttribute('aria-hidden', String(!next));
    if (next) {
      renderNotificationPreferences();
      setTimeout(() => $('closeNotificationSettings')?.focus(), 25);
    }
  }
  function closeNotificationSettings() { toggleNotificationSettings(false); }

  function wire(){
    document.addEventListener('click',(event)=>{
      const conflict=event.target.closest('[data-v69-conflict]'); if(conflict){const col=conflict.dataset.v69Conflict,res=conflict.dataset.resolution;conflict.disabled=true;window.LSOCloud?.resolveSyncConflict?.(col,res).then(()=>{toast(res==='remote'?'Shared version applied.':'Your pending version was saved after conflict review.');renderSyncStatus();}).catch(e=>toast(e.message||'Conflict could not be resolved.',true)).finally(()=>conflict.disabled=false);}
      const resolve=event.target.closest('[data-v69-quality-resolve]');if(resolve)resolveQuality(resolve);
      const jump=event.target.closest('[data-v69-jump]'); if(jump){const view=jump.dataset.v69Jump;if(window.LSORoleAccess?.canAccessView?.(view)===false)return toast('This module is not assigned to your role.',true);window.LSOApp?.setView?.(view);}
    });
    $('openNotificationSettingsFromNotifications')?.addEventListener('click',()=>toggleNotificationSettings(true));
    $('closeNotificationSettings')?.addEventListener('click',closeNotificationSettings);
    $('closeNotificationSettingsFooter')?.addEventListener('click',closeNotificationSettings);
    $('notificationSettingsModal')?.addEventListener('click',(event)=>{if(event.target===$('notificationSettingsModal'))closeNotificationSettings();});
    $('v69SyncTrigger')?.addEventListener('click',()=>toggleSync());$('v69SyncTrigger')?.addEventListener('keydown',e=>{if(e.key==='Enter'||e.key===' '){e.preventDefault();toggleSync();}});$('v69CloseSync')?.addEventListener('click',()=>toggleSync(false));$('v69SyncNow')?.addEventListener('click',async()=>{const btn=$('v69SyncNow');if(btn){btn.disabled=true;btn.textContent='Checking…';}try{if(window.LSOCloud?.recoverConnection)await window.LSOCloud.recoverConnection({source:'manual'});else{await window.LSOCloud?.flush?.();await window.LSOCloud?.pollNow?.();}}finally{if(btn){btn.disabled=false;btn.textContent='Sync Now';}renderSyncStatus();}});
    $('v69SaveNotificationPrefs')?.addEventListener('click',saveAccountPrefs);$('v69SaveRoleNotificationPrefs')?.addEventListener('click',saveRolePrefs);$('v69ResetNotificationPrefs')?.addEventListener('click',()=>{accountPrefs={};renderNotificationPreferences();});$('v69NotificationRole')?.addEventListener('change',async()=>{try{const payload=await window.LSOCloud?.getNotificationPreferences?.();rolePrefs=payload?.roleDefaults?.[$('v69NotificationRole').value]||payload?.rolePreferences||{};}catch{rolePrefs={};}renderNotificationPreferences();});
    $('dataQualityWorkflowStatus')?.addEventListener('change',()=>{window.LSOOperationsGovernanceV61?.renderDataQuality?.(false);setTimeout(enhanceQualityCards,20);});
    $('v69EnvironmentSelect')?.addEventListener('change',e=>{if(!isAdmin()){renderEnvironment();return;}if(updateSettings({[ENV_FIELD]:e.target.value},'deployment-environment')){renderEnvironment();toast(`Environment marked as ${e.target.value}.`);}});
    $('v69RunIntegrityCheck')?.addEventListener('click',runIntegrityCheck);
    document.addEventListener('keydown',e=>{if(e.key==='Escape'){toggleSync(false); closeNotificationSettings();}});
    const host=$('dataQualityIssues');if(host){qualityObserver=new MutationObserver(()=>setTimeout(enhanceQualityCards,0));qualityObserver.observe(host,{childList:true,subtree:false});}
    ['lso:members-changed','lso:operations-changed','lso:duty-hours-changed','lso:monthly-report-changed','lso:cloud-state-changed'].forEach(name=>window.addEventListener(name,()=>{scheduleAnalytics();renderEnvironment();}));
    ['lso:cloud-status','lso:cloud-saved','lso:sync-heartbeat','lso:sync-conflict','lso:sync-conflict-resolved','lso:connection-health'].forEach(name=>window.addEventListener(name,e=>{lastSyncEventAt=new Date().toISOString();renderSyncStatus();}));
    window.addEventListener('lso:auth-changed',()=>setTimeout(()=>{loadNotificationPreferences();renderEnvironment();refreshCapabilities();scheduleAnalytics();renderSyncStatus();},180));
    document.querySelector('[data-view="dashboardView"]')?.addEventListener('click',()=>setTimeout(renderDashboardAnalytics,40));
    document.querySelector('[data-view="dataView"]')?.addEventListener('click',()=>setTimeout(()=>{renderEnvironment();refreshCapabilities();},60));
  }

  function initialize(){renderEnvironment();wire();loadNotificationPreferences();refreshCapabilities();scheduleAnalytics();setTimeout(()=>{enhanceQualityCards();renderSyncStatus();},300);window.dispatchEvent(new CustomEvent('lso:v69-ready',{detail:{version:VERSION}}));}
  window.LSOPlatformV69={VERSION,renderDashboardAnalytics,runIntegrityCheck,renderSyncStatus,notificationAllows:allows};
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',initialize,{once:true});else initialize();
})();
