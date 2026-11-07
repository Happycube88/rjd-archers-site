// auth-status.js - shows "Signed in as ... | Sign out" (or a Member Login link) in the page header.
// Use: put <span id="authStatus"></span> in the nav, then load this file after the supabase-js script (head or end of body).
(function () {
  function init() {
  var SUPABASE_URL = 'https://onepmhddrqmvhyhagkth.supabase.co';
  var SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im9uZXBtaGRkcnFtdmh5aGFna3RoIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTI0NTU4MTQsImV4cCI6MjEwODAzMTgxNH0.puqAvMFt-SpG6cVedHFVSrLIx4NifALgbcJka1aXbfw';
  var el = document.getElementById('authStatus');
  if (!el || !window.supabase) return;
  var sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);   // shares the saved login on this site

  function show(session, level) {
    el.textContent = '';
    if (!session) {
      var a = document.createElement('a');
      a.href = '/db/edit-profile.html';
      a.textContent = 'Member Login';
      a.className = 'bg-purple-600 px-3 py-1.5 rounded hover:bg-purple-700 text-white shadow-sm';
      el.appendChild(a);
      return;
    }
    var who = document.createElement('span');
    who.textContent = 'Signed in: ' + session.user.email + ' ';
    who.className = 'text-xs text-green-700 font-semibold';
    el.appendChild(who);
    if (level === 'aal2') {
      var ok = document.createElement('span');
      ok.textContent = '2FA \u2713 ';
      ok.className = 'text-xs text-green-700 font-semibold';
      el.appendChild(ok);
    } else if (level === 'aal1') {
      var v = document.createElement('a');
      v.href = '/db/security.html?next=' + encodeURIComponent(location.pathname);
      v.textContent = 'Verify 2FA ';
      v.className = 'text-xs text-purple-700 underline';
      el.appendChild(v);
    }
    var out = document.createElement('button');
    out.textContent = 'Sign out';
    out.className = 'ml-2 bg-slate-700 px-3 py-1.5 rounded hover:bg-slate-900 text-white text-xs';
    out.onclick = function () { sb.auth.signOut().then(function () { location.reload(); }); };
    el.appendChild(out);
  }

  function refresh(session) {
    show(session, null);
    if (!session) return;
    sb.auth.mfa.getAuthenticatorAssuranceLevel().then(function (r) {
      if (r && r.data) show(session, r.data.currentLevel);
    });
  }

  sb.auth.getSession().then(function (r) { refresh(r.data.session); });
  // never call Supabase directly inside this callback (can deadlock): defer it
  sb.auth.onAuthStateChange(function (_e, session) { setTimeout(function () { refresh(session); }, 0); });
  }
  // wait for the page to finish loading, so the nav's <span id="authStatus"> exists
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
