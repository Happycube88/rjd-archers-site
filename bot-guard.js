// bot-guard.js - helps stop spam bots on the public forms (Contact us, Beginners sign-up).
// 1. Records when the page was opened, so the server can ignore forms "filled in" within 3 seconds.
// 2. Optional Cloudflare Turnstile check. To switch it on: create a free Turnstile widget in Cloudflare,
//    paste its SITE KEY below, and add its SECRET KEY in Cloudflare Pages as the secret TURNSTILE_SECRET.
//    While SITE_KEY is empty the check is off and everything else still works.
(function () {
  var SITE_KEY = '';
  var opened = Date.now(), token = '';
  window.rjdBot = function () { return { t: opened, ts: token }; };
  window.rjdBotReset = function () { token = ''; try { if (window.turnstile) window.turnstile.reset(); } catch (e) {} };
  if (!SITE_KEY) return;
  window.__rjdTs = function (t) { token = t; };
  var box = document.getElementById('tsBox');
  if (!box) return;
  box.className = 'cf-turnstile my-2';
  box.setAttribute('data-sitekey', SITE_KEY);
  box.setAttribute('data-callback', '__rjdTs');
  var s = document.createElement('script');
  s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js'; s.async = true; s.defer = true;
  document.head.appendChild(s);
})();
