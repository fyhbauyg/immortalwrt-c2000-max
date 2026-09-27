(function () {
 'use strict';
 function ready() {
  var sidebar = document.getElementById('cpe37-sidebar');
  var topmenu = document.getElementById('topmenu');
  var backdrop = document.getElementById('cpe37-backdrop');
  var toggle = document.getElementById('cpe37-menu-button');
  var search = document.getElementById('cpe37-menu-search');
  if (!sidebar || !topmenu || !toggle) return;
  function open() { document.body.classList.add('cpe37-menu-open'); toggle.setAttribute('aria-expanded', 'true'); backdrop.hidden = false; }
  function close() { document.body.classList.remove('cpe37-menu-open'); toggle.setAttribute('aria-expanded', 'false'); backdrop.hidden = true; }
  toggle.addEventListener('click', function () { document.body.classList.contains('cpe37-menu-open') ? close() : open(); });
  document.getElementById('cpe37-sidebar-close').addEventListener('click', close);
  var bottom = document.getElementById('cpe37-bottom-menu');
  if (bottom) bottom.addEventListener('click', function () { open(); search.focus(); });
  backdrop.addEventListener('click', close);
  document.addEventListener('keydown', function (event) { if (event.key === 'Escape') close(); });
  var theme = document.getElementById('cpe37-theme-button');
  if (theme) theme.addEventListener('click', window.cpe37ToggleTheme);
  function markActive() {
   var path = window.location.pathname.replace(/\/$/, '');
   Array.prototype.forEach.call(topmenu.children, function (li) {
    if (li.tagName !== 'LI') return;
    var links = li.querySelectorAll('a[href]:not([href="#"])');
    var active = Array.prototype.some.call(links, function (a) { var href = new URL(a.href).pathname.replace(/\/$/, ''); return path === href || path.indexOf(href + '/') === 0; });
    li.classList.toggle('cpe37-active-group', active);
   });
   Array.prototype.forEach.call(document.querySelectorAll('[data-cpe37-tab]'), function (a) {
    var href = new URL(a.href).pathname.replace(/\/$/, '');
    a.classList.toggle('active', path === href || path.indexOf(href + '/') === 0);
   });
  }
  function filter() {
   var query = search.value.trim().toLocaleLowerCase();
   Array.prototype.forEach.call(topmenu.children, function (li) {
    if (li.tagName !== 'LI') return;
    var heading = li.firstElementChild;
    var category = heading && heading.textContent.toLocaleLowerCase().indexOf(query) !== -1;
    var found = category;
    Array.prototype.forEach.call(li.querySelectorAll('ul li'), function (child) {
     var match = !query || category || child.textContent.toLocaleLowerCase().indexOf(query) !== -1;
     child.hidden = !match;
     if (match) found = true;
    });
    li.hidden = !!query && !found;
   });
  }
  search.addEventListener('input', filter);
  sidebar.addEventListener('click', function (event) {
   var a = event.target.closest('a');
   if (!a) return;
   if (a.getAttribute('href') === '#') { event.preventDefault(); return; }
   if (window.matchMedia('(max-width: 900px)').matches) close();
  });
  var observer = new MutationObserver(function () { markActive(); filter(); });
  observer.observe(topmenu, { childList: true });
  markActive();
 }
 if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', ready); else ready();
}());
