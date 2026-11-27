/* devbox docs: tabs for the captured sessions, and the Copy button. No dependencies, no network. */
(function () {
  'use strict';

  // ---- tabs (WAI-ARIA tabs pattern, automatic activation) ----
  var tabs = Array.prototype.slice.call(document.querySelectorAll('[role="tab"]'));
  function show(tab) {
    tabs.forEach(function (t) {
      var on = t === tab;
      t.setAttribute('aria-selected', on ? 'true' : 'false');
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
    });
  }
  if (tabs.length) {
    tabs.forEach(function (t, i) {
      t.addEventListener('click', function () { show(t); });
      t.addEventListener('keydown', function (e) {
        var j = -1;
        if (e.key === 'ArrowRight') j = (i + 1) % tabs.length;
        else if (e.key === 'ArrowLeft') j = (i - 1 + tabs.length) % tabs.length;
        else if (e.key === 'Home') j = 0;
        else if (e.key === 'End') j = tabs.length - 1;
        if (j < 0) return;
        e.preventDefault();
        show(tabs[j]);
        tabs[j].focus();
      });
    });
    show(tabs[0]);
  }

  // ---- copy buttons ----
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) return navigator.clipboard.writeText(text);
    return new Promise(function (resolve, reject) {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.setAttribute('aria-hidden', 'true');
      ta.style.cssText = 'position:fixed;top:0;left:0;opacity:0';
      document.body.appendChild(ta);
      ta.select();
      var ok = false;
      try { ok = document.execCommand('copy'); } catch (err) { ok = false; }
      document.body.removeChild(ta);
      ok ? resolve() : reject(new Error('copy failed'));
    });
  }

  Array.prototype.forEach.call(document.querySelectorAll('[data-copy]'), function (btn) {
    var box = btn.parentNode;
    var source = box.querySelector('.install');
    var label = btn.querySelector('[data-copy-label]');
    var status = box.querySelector('[data-copy-status]');
    var timer;
    function done(ok) {
      label.textContent = ok ? 'Copied' : 'Copy';
      btn.setAttribute('data-state', ok ? 'done' : '');
      status.textContent = ok ? 'Copied to the clipboard.' : 'Could not copy. Select the command and copy it by hand.';
      clearTimeout(timer);
      timer = setTimeout(function () {
        label.textContent = 'Copy';
        btn.removeAttribute('data-state');
        status.textContent = '';
      }, 2500);
    }
    btn.addEventListener('click', function () {
      copyText(source.textContent.trim()).then(function () { done(true); }, function () { done(false); });
    });
  });
})();
