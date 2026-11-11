// site-nav.js - the one shared site header (logo, grouped menu, phone menu, account button).
// Every page puts <script src="/site-nav.js"></script> where its header goes. Change the menu here, once.
(function () {
  var path = location.pathname.replace(/\/index\.html$/, '/');
  var GROUPS = [
    { label: 'Home', href: '/index.html', match: ['/'] },
    { label: 'Join', items: [
      { label: "Beginner's Courses", href: '/Beginners.html' },
      { label: 'Fees & Costs', href: '/fees.html' }] },
    { label: 'Tournaments & Results', href: '/tournaments.html' },
    { label: 'Club', items: [
      { label: 'Club Records', href: '/records.html' },
      { label: 'Venues & Location', href: '/location.html' },
      { label: 'Calendar', href: '/calendar.html' },
      { label: 'Local Clubs & Map', href: '/links.html' },
      { label: 'News', href: '/news.html' },
      { label: 'Welfare & Policies', href: '/policies.html' },
      { label: 'Contact Us', href: '/contacts.html' }] }
  ];
  function here(href) { return path.toLowerCase() === href.toLowerCase() || (href === '/index.html' && path === '/'); }
  var base = 'text-purple-800 hover:text-purple-950 font-medium';
  var nav = GROUPS.map(function (g, i) {
    if (!g.items) return '<a href="' + g.href + '" class="' + base + (here(g.href) ? ' font-bold underline' : '') + ' px-2 py-1.5 block">' + g.label + '</a>';
    var active = g.items.some(function (it) { return here(it.href); });
    return '<div class="relative" data-group>' +
      '<button type="button" aria-haspopup="true" aria-expanded="false" class="' + base + (active ? ' font-bold underline' : '') + ' px-2 py-1.5 flex items-center gap-1" data-toggle>' + g.label + ' <span aria-hidden="true">&#9662;</span></button>' +
      '<div class="hidden md:absolute md:left-0 md:top-full md:mt-1 md:w-56 md:bg-white md:border md:border-slate-200 md:rounded-lg md:shadow-lg md:z-40 md:py-1 pl-3 md:pl-0" data-menu>' +
      g.items.map(function (it) { return '<a href="' + it.href + '" class="block px-3 py-1.5 text-sm text-purple-800 hover:bg-purple-50' + (here(it.href) ? ' font-bold' : '') + '">' + it.label + '</a>'; }).join('') +
      '</div></div>';
  }).join('');
  var html =
    '<header class="bg-gradient-to-r from-white via-slate-200 to-slate-300 text-slate-900 shadow-md border-b border-slate-200 relative z-30">' +
    '<div class="max-w-6xl mx-auto px-4 py-3 flex flex-wrap items-center justify-between gap-3">' +
      '<a href="/index.html" class="flex items-center gap-3 group">' +
        '<img src="/logo.jpg" alt="RJD Archers logo" width="40" height="40" class="h-10 w-auto object-contain">' +
        '<span class="text-2xl font-bold tracking-wide text-purple-900 group-hover:text-purple-700 transition">RJD Archers</span></a>' +
      '<button type="button" id="navBurger" class="md:hidden border border-purple-300 text-purple-900 rounded px-3 py-1.5 text-sm font-semibold" aria-controls="navBody" aria-expanded="false">Menu</button>' +
      '<div id="navBody" class="hidden md:flex w-full md:w-auto flex-col md:flex-row md:items-center gap-1 md:gap-3 text-sm">' + nav +
        '<span id="authStatus" class="pt-2 md:pt-0"></span></div>' +
    '</div></header>';
  var s = document.currentScript;
  if (s) s.insertAdjacentHTML('beforebegin', html); else document.write(html);

  function closeAll(except) {
    document.querySelectorAll('[data-group]').forEach(function (g) {
      if (g === except) return;
      g.querySelector('[data-menu]').classList.add('hidden');
      g.querySelector('[data-toggle]').setAttribute('aria-expanded', 'false');
    });
  }
  document.addEventListener('click', function (e) {
    var t = e.target.closest ? e.target.closest('[data-toggle]') : null;
    if (t) {
      var g = t.parentNode, m = g.querySelector('[data-menu]'), open = m.classList.contains('hidden');
      closeAll(g); m.classList.toggle('hidden', !open); t.setAttribute('aria-expanded', open ? 'true' : 'false');
      return;
    }
    if (e.target.closest && e.target.closest('#navBurger')) {
      var b = document.getElementById('navBody'), o = b.classList.contains('hidden');
      b.classList.toggle('hidden', !o); document.getElementById('navBurger').setAttribute('aria-expanded', o ? 'true' : 'false');
      return;
    }
    if (!(e.target.closest && e.target.closest('[data-group]'))) closeAll(null);
  });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') closeAll(null); });
  // on a phone the group lists are always open inside the opened Menu
  var mq = window.matchMedia('(min-width: 768px)');
  function phone() { if (!mq.matches) document.querySelectorAll('[data-menu]').forEach(function (m) { m.classList.remove('hidden'); }); }
  phone(); if (mq.addEventListener) mq.addEventListener('change', function () { document.querySelectorAll('[data-menu]').forEach(function (m) { m.classList.toggle('hidden', mq.matches); }); phone(); });
})();
