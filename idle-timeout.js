// idle-timeout.js - signs people out after a period of inactivity, and after a maximum session length.
// Signing out also ends the 2FA check, so the next sign-in needs a new email link and a new 2FA code.
// Committee pages: 15 minutes idle. Other pages: 30 minutes idle. Anyone: 8 hours maximum.
(function () {
  var KEY = 'sb-onepmhddrqmvhyhagkth-auth-token', ACT = 'rjd-last-activity', START = 'rjd-session-start';
  var committee = /^\/(committee\.html|db\/committee)/.test(location.pathname);
  var IDLE = (committee ? 15 : 30) * 60 * 1000, MAX = 8 * 60 * 60 * 1000;
  function get(k) { try { return +localStorage.getItem(k) || 0; } catch (e) { return 0; } }
  function set(k, v) { try { localStorage.setItem(k, String(v)); } catch (e) {} }
  function loggedIn() { try { return !!localStorage.getItem(KEY); } catch (e) { return false; } }
  var last = 0;
  function touch() { var n = Date.now(); if (n - last > 15000) { last = n; set(ACT, n); } }
  ['click', 'keydown', 'touchstart', 'scroll', 'mousemove'].forEach(function (e) { window.addEventListener(e, touch, { passive: true }); });
  function out() {
    try { localStorage.removeItem(KEY); localStorage.removeItem(ACT); localStorage.removeItem(START); } catch (e) {}
    location.href = '/members.html?timedout=1';
  }
  function check() {
    if (!loggedIn()) { try { localStorage.removeItem(START); } catch (e) {} return; }
    var n = Date.now(), a = get(ACT), s = get(START);
    if (!s) { set(START, n); s = n; }
    if (!a) { set(ACT, n); a = n; }
    if (n - a > IDLE || n - s > MAX) out();
  }
  check(); touch();
  setInterval(check, 30000);
  document.addEventListener('visibilitychange', function () { if (!document.hidden) check(); });
})();
