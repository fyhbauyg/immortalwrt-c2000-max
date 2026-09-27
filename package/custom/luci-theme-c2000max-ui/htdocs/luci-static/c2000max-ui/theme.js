/* Synchronous in <head>: apply the appearance before first paint. */
(() => {
  'use strict';
  const key = 'c2000-appearance';
  const system = matchMedia('(prefers-color-scheme: dark)');
  const compact = matchMedia('(max-width: 700px)');
  const choices = ['system', 'light', 'dark'];
  let preference = 'system';
  try { const saved = localStorage.getItem(key); if (choices.includes(saved)) preference = saved; } catch {}
  function apply() {
    const resolved = preference === 'system' ? (system.matches ? 'dark' : 'light') : preference;
    document.documentElement.dataset.theme = resolved;
    document.documentElement.dataset.appearance = preference;
    document.querySelectorAll('[data-theme-choice]').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.themeChoice === preference)));
    document.querySelectorAll('[data-theme-toggle]').forEach(toggle => {
      const selected = toggle.parentElement.querySelector('[data-theme-choice="' + preference + '"]');
      const name = selected.getAttribute('aria-label');
      toggle.replaceChildren(selected.querySelector('svg').cloneNode(true));
      toggle.setAttribute('aria-label', '外观模式：' + name);
      toggle.title = '外观模式：' + name;
    });
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', resolved === 'dark' ? '#111111' : '#eef3f8');
  }
  function set(value) {
    if (!choices.includes(value)) return;
    preference = value;
    try { localStorage.setItem(key, value); } catch {}
    apply();
  }
  function closePickers(restoreFocus = false) {
    document.querySelectorAll('[data-theme-toggle][aria-expanded="true"]').forEach(toggle => {
      toggle.setAttribute('aria-expanded', 'false');
      if (restoreFocus && compact.matches) toggle.focus();
    });
  }
  apply();
  system.addEventListener('change', apply);
  window.addEventListener('storage', event => {
    if (event.key === key || event.key === null) { preference = choices.includes(event.newValue) ? event.newValue : 'system'; apply(); }
  });
  document.addEventListener('DOMContentLoaded', apply);
  document.addEventListener('click', event => {
    const toggle = event.target.closest('[data-theme-toggle]');
    if (toggle) {
      const opening = toggle.getAttribute('aria-expanded') !== 'true';
      closePickers();
      toggle.setAttribute('aria-expanded', String(opening));
      if (opening) toggle.parentElement.querySelector('[aria-pressed="true"]').focus();
      return;
    }
    const button = event.target.closest('[data-theme-choice]');
    if (button) { set(button.dataset.themeChoice); closePickers(true); }
    else if (!event.target.closest('.theme-picker')) closePickers();
  });
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape') closePickers(true);
  });
  document.addEventListener('focusin', event => {
    if (!event.target.closest('.theme-picker')) closePickers();
  });
  compact.addEventListener('change', () => {
    const toggleFocused = document.activeElement?.matches('[data-theme-toggle]');
    closePickers();
    if (!compact.matches && toggleFocused) document.querySelector('[data-theme-choice][aria-pressed="true"]')?.focus();
  });
  window.C2000Theme = Object.freeze({ set, get: () => preference });
})();
