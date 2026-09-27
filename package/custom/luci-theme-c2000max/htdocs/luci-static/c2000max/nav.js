(function () {
  'use strict';
  function init() {
    var button = document.getElementById('c2k-menu-toggle');
    var sidebar = document.getElementById('c2k-sidebar');
    var backdrop = document.getElementById('c2k-drawer-backdrop');
    if (!button || !sidebar || !backdrop) return;
    var search = document.getElementById('c2k-menu-search');
    var mobileSearch = document.getElementById('c2k-mobile-menu-search');
    var topmenu = document.getElementById('topmenu');
    var iconBase = '/luci-static/c2000max/icons.svg?v=1.2.0#';

    function close() {
      document.body.classList.remove('c2k-sidebar-open');
      button.setAttribute('aria-expanded', 'false');
      backdrop.hidden = true;
    }
    button.addEventListener('click', function () {
      var open = !document.body.classList.contains('c2k-sidebar-open');
      document.body.classList.toggle('c2k-sidebar-open', open);
      button.setAttribute('aria-expanded', open ? 'true' : 'false');
      backdrop.hidden = !open;
    });
    backdrop.addEventListener('click', close);

    function topItems() { return topmenu ? Array.prototype.slice.call(topmenu.children).filter(function (n) { return n.tagName === 'LI'; }) : []; }
    function categoryIcon(item) {
      var link = item.querySelector('a[href*="/admin/"]');
      var match = link && link.getAttribute('href').match(/\/admin\/([^/?#]+)/);
      var category = match ? match[1] : '';
      return /^(status|network|services|system|vpn|storage|modem|statistics|nas|logout)$/.test(category) ? category : 'grid';
    }
    function decorate() {
      topItems().forEach(function (item) {
        var link = item.querySelector('a');
        if (!link || link.querySelector('.c2k-menu-icon')) return;
        var icon = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
        icon.setAttribute('class', 'c2k-menu-icon');
        icon.setAttribute('aria-hidden', 'true');
        var use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
        use.setAttribute('href', iconBase + categoryIcon(item));
        icon.appendChild(use);
        link.insertBefore(icon, link.firstChild);
      });
      var path = window.location.pathname.replace(/\/$/, '');
      topItems().forEach(function (item) {
        var links = item.querySelectorAll('a[href]:not([href="#"])');
        var active = false;
        for (var i = 0; i < links.length; i++) {
          var href = new URL(links[i].getAttribute('href'), window.location.href).pathname.replace(/\/$/, '');
          if (href && (path === href || path.indexOf(href + '/') === 0)) active = true;
        }
        item.classList.toggle('c2k-current', active);
        if (!item.dataset.c2kInitialized) {
          item.dataset.c2kInitialized = '1';
          if (!active && item.querySelector('.dropdown-menu')) item.classList.add('c2k-collapsed');
        }
      });
      filter();
    }
    function filter() {
      if (!topmenu || !search) return;
      var query = search.value.trim().toLocaleLowerCase();
      topItems().forEach(function (category) {
        var categoryLink = category.querySelector('a');
        var categoryMatch = !!query && !!categoryLink && categoryLink.textContent.toLocaleLowerCase().indexOf(query) !== -1;
        var children = category.querySelectorAll('li');
        var childMatch = false;
        for (var i = 0; i < children.length; i++) {
          var match = !query || categoryMatch || children[i].textContent.toLocaleLowerCase().indexOf(query) !== -1;
          children[i].hidden = !match;
          if (match) childMatch = true;
        }
        category.hidden = !!query && !categoryMatch && !childMatch && category.textContent.toLocaleLowerCase().indexOf(query) === -1;
        if (query && !category.hidden) category.classList.remove('c2k-collapsed');
        else if (!query && !category.classList.contains('c2k-current') && !category.dataset.c2kUserToggle && category.querySelector('.dropdown-menu')) category.classList.add('c2k-collapsed');
      });
    }
    if (topmenu) {
      var pending = false;
      var observer = new MutationObserver(function () {
        if (pending) return;
        pending = true;
        window.requestAnimationFrame(function () { pending = false; decorate(); });
      });
      observer.observe(topmenu, { childList: true, subtree: true });
      decorate();
    }
    if (search) {
      search.addEventListener('input', function () { if (mobileSearch) mobileSearch.value = search.value; filter(); });
      if (mobileSearch) mobileSearch.addEventListener('input', function () { search.value = mobileSearch.value; filter(); });
      document.addEventListener('keydown', function (event) {
        if (event.key === '/' && document.activeElement !== search && document.activeElement !== mobileSearch && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) { event.preventDefault(); (window.matchMedia('(max-width: 600px)').matches && mobileSearch ? mobileSearch : search).focus(); }
        else if (event.key === 'Escape' && (document.activeElement === search || document.activeElement === mobileSearch)) { search.value = ''; if (mobileSearch) mobileSearch.value = ''; filter(); document.activeElement.blur(); }
      });
    }
    document.addEventListener('keydown', function (event) { if (event.key === 'Escape') close(); });
    sidebar.addEventListener('click', function (event) {
      var link = event.target.closest ? event.target.closest('a') : null;
      if (!link) return;
      if (link.getAttribute('href') === '#') { event.preventDefault(); link.parentElement.dataset.c2kUserToggle = '1'; link.parentElement.classList.toggle('c2k-collapsed'); }
      else { if (search && search.value) { search.value = ''; if (mobileSearch) mobileSearch.value = ''; filter(); } if (window.matchMedia('(max-width: 900px)').matches) close(); }
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
}());
