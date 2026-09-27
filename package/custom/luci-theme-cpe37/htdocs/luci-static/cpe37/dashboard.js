(function () {
  'use strict';

  function isOverviewPage() {
    var p = location.pathname;
    if (/\/admin\/status\/overview\/?$/.test(p) || p === '/cgi-bin/luci' || p === '/cgi-bin/luci/') {
      return true;
    }
    if (window.L && L.env && Array.isArray(L.env.dispatchpath)) {
      var dp = L.env.dispatchpath.join('/');
      if (dp === 'admin/status/overview' || dp === 'admin/status' || dp === '') {
        return true;
      }
    }
    return false;
  }

  function ensureStylesheet() {
    if (!document.getElementById('cpe-dashboard-style')) {
      var link = document.createElement('link');
      link.id = 'cpe-dashboard-style';
      link.rel = 'stylesheet';
      link.href = '/luci-static/cpe37/cpe-dashboard.css?v=1.0.1';
      document.head.appendChild(link);
    }
  }

  function mount() {
    if (!isOverviewPage()) {
      document.body.classList.remove('cpe37-dashboard-active');
      return false;
    }

    var view = document.getElementById('view');
    if (!view || !view.parentNode) return false;
    if (document.getElementById('cpe-root')) return true;

    ensureStylesheet();

    // Apply dashboard active class to hide outer cpe37 shell and allow full-width Apple HIG layout
    document.body.classList.add('cpe37-dashboard-active');

    // Hide native LuCI title
    var title = document.querySelector('#maincontent h2[name="content"]');
    if (title) title.hidden = true;

    // Create container for modern CPE dashboard
    var container = document.createElement('div');
    container.id = 'cpe-root';
    view.parentNode.insertBefore(container, view);

    // Tuck native LuCI view into collapsible details
    var details = document.createElement('details');
    details.className = 'cpe37-original';
    var summary = document.createElement('summary');
    summary.textContent = '查看原生 LuCI 完整设备状态信息';
    details.appendChild(summary);
    view.parentNode.insertBefore(details, view);
    details.appendChild(view);

    // Function to mount React dashboard
    function doMount() {
      if (typeof window.mountCpeDashboard === 'function') {
        window.mountCpeDashboard(container);
      } else {
        container.innerHTML = '<div style="padding:60px 20px;text-align:center;color:#86868b;font-family:-apple-system,sans-serif;">正在载入 CPE 控制台...</div>';
        var pollCount = 0;
        var pollTimer = setInterval(function () {
          if (typeof window.mountCpeDashboard === 'function') {
            clearInterval(pollTimer);
            window.mountCpeDashboard(container);
          } else if (++pollCount > 40) {
            clearInterval(pollTimer);
            container.innerHTML = '<div style="padding:60px 20px;text-align:center;color:#ff3b30;font-family:-apple-system,sans-serif;">加载 CPE 控制台脚本超时。<br><button onclick="location.reload()" style="margin-top:12px;padding:6px 16px;border-radius:8px;background:#0071e3;color:#fff;border:none;cursor:pointer;font-size:13px;">刷新重试</button></div>';
          }
        }, 100);
      }
    }

    if (typeof window.mountCpeDashboard === 'function') {
      setTimeout(doMount, 0);
    } else {
      var candidates = [
        '/luci-static/cpe37/cpe-dashboard.js?v=1.0.1',
        (window.L && L.env && L.env.mediaurlbase ? L.env.mediaurlbase + '/cpe-dashboard.js?v=1.0.1' : ''),
        (window.L && L.env && L.env.resource ? L.env.resource + '/cpe37/cpe-dashboard.js?v=1.0.1' : '')
      ].filter(Boolean);

      var idx = 0;
      function tryNext() {
        if (typeof window.mountCpeDashboard === 'function') {
          doMount();
          return;
        }
        if (idx >= candidates.length) {
          container.innerHTML = '<div style="padding:60px 20px;text-align:center;color:#ff3b30;font-family:-apple-system,sans-serif;">加载 CPE 控制台脚本失败。请刷新重试。<br><button onclick="location.reload()" style="margin-top:12px;padding:6px 16px;border-radius:8px;background:#0071e3;color:#fff;border:none;cursor:pointer;font-size:13px;">刷新重试</button></div>';
          return;
        }
        var s = document.createElement('script');
        s.type = 'module';
        s.src = candidates[idx++];
        s.onload = function () {
          doMount();
        };
        s.onerror = function () {
          s.remove();
          tryNext();
        };
        document.head.appendChild(s);
      }
      tryNext();
    }
    return true;
  }

  // Periodic check & SPA route changes
  var lastLoc = '';
  setInterval(function () {
    var cur = location.pathname + location.search;
    if (cur !== lastLoc) {
      lastLoc = cur;
      if (isOverviewPage()) {
        mount();
      } else {
        document.body.classList.remove('cpe37-dashboard-active');
        var oldRoot = document.getElementById('cpe-root');
        if (oldRoot) oldRoot.remove();
        var oldDetails = document.querySelector('.cpe37-original');
        if (oldDetails) {
          var view = document.getElementById('view');
          if (view && oldDetails.contains(view)) {
            oldDetails.parentNode.insertBefore(view, oldDetails);
          }
          oldDetails.remove();
        }
        var title = document.querySelector('#maincontent h2[name="content"]');
        if (title) title.hidden = false;
      }
    } else if (isOverviewPage() && !document.getElementById('cpe-root')) {
      mount();
    }
  }, 250);

  if (document.readyState !== 'loading') {
    mount();
  } else {
    document.addEventListener('DOMContentLoaded', mount);
  }
})();
