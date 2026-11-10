// auth-status.js - compact account menu in the page header.
// Use: put <span id="authStatus"></span> in the nav, then load this file after the supabase-js script (head or end of body).
// Signed out: a "Member Login" button. Signed in: a small "My account" button that opens a menu
// (email, 2FA state, Members area, Committee area for committee and Session leads, Sign out).
(function () {
  function init() {
  var SUPABASE_URL = 'https://onepmhddrqmvhyhagkth.supabase.co';
  var SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uZXBtaGRkcnFtdmh5aGFna3RoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NTU4MTQsImV4cCI6MjEwODAzMTgxNH0.puqAvMFt-SpG6cVedHFVSrLIx4NifALgbcJka1aXbfw';
  var el = document.getElementById('authStatus');
  if (!el || !window.supabase) return;
  var sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);   // shares the saved login on this site
  var roles = { committee: false, lead: false }, open = false;

  function mk(tag, cls, text) { var e = document.createElement(tag); if (cls) e.className = cls; if (text) e.textContent = text; return e; }
  function link(href, text, cls) { var a = mk('a', cls || 'block px-3 py-2 text-sm text-purple-800 hover:bg-purple-50', text); a.href = href; return a; }

  function show(session, level) {
    el.textContent = '';
    el.className = 'relative inline-block';
    if (!session) {
      var a = link('/members.html', 'Member Login', 'bg-purple-600 px-3 py-1.5 rounded hover:bg-purple-700 text-white shadow-sm');
      el.appendChild(a);
      return;
    }
    var btn = mk('button', 'bg-purple-700 hover:bg-purple-800 text-white text-sm px-3 py-1.5 rounded shadow-sm whitespace-nowrap', 'My account ');
    btn.type = 'button';
    btn.setAttribute('aria-haspopup', 'true');
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
    if (level === 'aal2') btn.appendChild(mk('span', 'text-green-300', '\u2713'));
    else if (level === 'aal1') btn.appendChild(mk('span', 'text-amber-300', '!'));
    btn.appendChild(mk('span', '', ' \u25BE'));
    el.appendChild(btn);

    var menu = mk('div', 'absolute right-0 mt-2 w-64 bg-white border border-slate-200 rounded-lg shadow-lg z-50 overflow-hidden' + (open ? '' : ' hidden'));
    menu.appendChild(mk('div', 'px-3 py-2 text-xs text-slate-500 border-b border-slate-100 break-all', session.user.email));
    if (level === 'aal2') menu.appendChild(mk('div', 'px-3 py-2 text-xs text-green-700 font-semibold border-b border-slate-100', '2FA verified \u2713'));
    else if (level === 'aal1') menu.appendChild(link('/db/security.html?next=' + encodeURIComponent(location.pathname), 'Verify 2FA to make changes', 'block px-3 py-2 text-xs text-amber-700 font-semibold border-b border-slate-100 hover:bg-amber-50'));
    menu.appendChild(link('/members.html', 'Members area'));
    if (roles.committee) menu.appendChild(link('/committee.html', 'Committee area'));
    else if (roles.lead) menu.appendChild(link('/db/committee-club-nights.html', 'Club night attendees'));
    menu.appendChild(link('/db/security.html', 'Security and 2FA'));
    var out = mk('button', 'block w-full text-left px-3 py-2 text-sm text-slate-700 hover:bg-slate-100 border-t border-slate-100', 'Sign out');
    out.type = 'button';
    out.onclick = function () { sb.auth.signOut().then(function () { location.reload(); }); };
    menu.appendChild(out);
    el.appendChild(menu);
    btn.onclick = function (e) { e.stopPropagation(); open = !open; menu.classList.toggle('hidden', !open); btn.setAttribute('aria-expanded', open ? 'true' : 'false'); };
  }

  function refresh(session) {
    show(session, null);
    if (!session) return;
    sb.auth.mfa.getAuthenticatorAssuranceLevel().then(function (r) {
      var level = r && r.data ? r.data.currentLevel : null;
      show(session, level);
      Promise.all([sb.rpc('is_committee'), sb.rpc('is_session_lead')]).then(function (v) {
        roles.committee = !!(v[0] && v[0].data === true); roles.lead = !!(v[1] && v[1].data === true);
        show(session, level);
      }).catch(function () {});
    });
  }

  document.addEventListener('click', function () { if (open) { open = false; var m = el.querySelector('div.absolute'); if (m) m.classList.add('hidden'); } });
  sb.auth.getSession().then(function (r) { refresh(r.data.session); });
  // never call Supabase directly inside this callback (can deadlock): defer it
  sb.auth.onAuthStateChange(function (_e, session) { setTimeout(function () { refresh(session); }, 0); });
  }
  // wait for the page to finish loading, so the nav's <span id="authStatus"> exists
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
