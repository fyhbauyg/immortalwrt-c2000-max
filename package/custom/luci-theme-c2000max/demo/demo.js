(function () {
  'use strict';
  var search = document.getElementById('c2k-demo-search');
  var nav = document.getElementById('c2k-demo-nav');
  if (!search || !nav) return;
  var entries = Array.prototype.slice.call(nav.querySelectorAll('li'));
  function filter() {
    var query = search.value.trim().toLocaleLowerCase();
    entries.forEach(function (item) {
      item.hidden = !!query && item.textContent.toLocaleLowerCase().indexOf(query) === -1;
    });
  }
  search.addEventListener('input', filter);
  document.addEventListener('keydown', function (event) {
    if (event.key === '/' && document.activeElement !== search && !/INPUT|TEXTAREA/.test(document.activeElement.tagName)) {
      event.preventDefault(); search.focus();
    } else if (event.key === 'Escape' && document.activeElement === search) {
      search.value = ''; filter(); search.blur();
    }
  });
  nav.addEventListener('click', function (event) {
    var link = event.target.closest('a');
    if (!link) return;
    entries.forEach(function (item) { item.classList.remove('c2k-current'); });
    link.parentElement.classList.add('c2k-current');
    if (search.value) { search.value = ''; filter(); }
  });
}());
