(function () {
  'use strict';
  var key = 'cpeargon-mode';
  var media = window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)');
  function stored() {
    try { return localStorage.getItem(key) || 'auto'; } catch (e) { return 'auto'; }
  }
  function resolved(mode) { return mode === 'auto' ? (media && media.matches ? 'dark' : 'light') : mode; }
  function syncStylesheet() {
    var link = document.getElementById('cpe-argon-dark');
    if (link) link.media = document.documentElement.dataset.theme === 'cpe-dark' ? 'all' : 'not all';
  }
  function apply(mode, save) {
    if (mode !== 'auto' && mode !== 'light' && mode !== 'dark') mode = 'auto';
    if (save) { try { localStorage.setItem(key, mode); } catch (e) {} }
    document.documentElement.dataset.theme = 'cpe-' + resolved(mode);
    document.documentElement.dataset.themeMode = mode;
    document.documentElement.style.colorScheme = resolved(mode);
    syncStylesheet();
    Array.prototype.forEach.call(document.querySelectorAll('input[name="cpe-theme"]'), function (input) {
      input.checked = input.value === mode;
    });
  }
  function bindControls() {
    apply(stored(), false);
    Array.prototype.forEach.call(document.querySelectorAll('input[name="cpe-theme"]'), function (input) {
      input.addEventListener('change', function () { if (input.checked) apply(input.value, true); });
    });
  }
  window.CpeTheme = { apply: apply, bindControls: bindControls, syncStylesheet: syncStylesheet };
  apply(stored(), false);
  if (media && media.addEventListener) media.addEventListener('change', function () {
    if (stored() === 'auto') apply('auto', false);
  });
}());
