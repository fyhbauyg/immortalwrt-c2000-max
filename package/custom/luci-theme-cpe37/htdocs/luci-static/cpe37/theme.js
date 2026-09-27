(function () {
  var key = 'cpe37-color-mode';
  var choice;
  try { choice = localStorage.getItem(key); } catch (e) {}
  var query = window.matchMedia('(prefers-color-scheme: dark)');
  function apply() { document.documentElement.classList.toggle('cpe37-dark', choice === 'dark' || (!choice && query.matches)); }
  apply();
  if (query.addEventListener) query.addEventListener('change', apply);
  window.cpe37ToggleTheme = function () { choice = document.documentElement.classList.contains('cpe37-dark') ? 'light' : 'dark'; try { localStorage.setItem(key, choice); } catch (e) {} apply(); };
}());
