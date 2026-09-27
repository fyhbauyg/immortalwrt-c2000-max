(function () {
	'use strict';
	var key = 'c2000max-theme';
	var root = document.documentElement;
	var media = window.matchMedia ? window.matchMedia('(prefers-color-scheme: dark)') : null;
	var mode = 'auto';

	try {
		var saved = window.localStorage.getItem(key);
		if (saved === 'auto' || saved === 'c2000max-light' || saved === 'c2000max-dark') mode = saved;
	} catch (_) { /* private browsing can deny storage */ }

	function apply() {
		var dark = mode === 'c2000max-dark' || (mode === 'auto' && !!(media && media.matches));
		root.setAttribute('data-theme', dark ? 'c2000max-dark' : 'c2000max-light');
		root.setAttribute('data-darkmode', dark ? 'true' : 'false');
		root.style.colorScheme = dark ? 'dark' : 'light';
		var controls = document.querySelectorAll('input[name="c2k-theme"]');
		for (var i = 0; i < controls.length; i++) controls[i].checked = controls[i].value === mode;
	}

	function setMode(next) {
		if (next !== 'auto' && next !== 'c2000max-light' && next !== 'c2000max-dark') return;
		mode = next;
		try { window.localStorage.setItem(key, next); } catch (_) { /* continue without persistence */ }
		apply();
	}

	apply();
	if (media) {
		if (media.addEventListener) media.addEventListener('change', function () { if (mode === 'auto') apply(); });
		else if (media.addListener) media.addListener(function () { if (mode === 'auto') apply(); });
	}
	document.addEventListener('DOMContentLoaded', function () {
		apply();
		var controls = document.querySelectorAll('input[name="c2k-theme"]');
		for (var i = 0; i < controls.length; i++) controls[i].addEventListener('change', function () { if (this.checked) setMode(this.value); });
	});
	window.C2000MAXTheme = { setMode: setMode, getMode: function () { return mode; } };
}());
