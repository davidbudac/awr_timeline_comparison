/*
 * Project website behaviour, shared by every page: theme toggle (same
 * localStorage key as the generated report, "awr-theme"), copy buttons on
 * code blocks, the narrow-layout menu, and the contents highlight.
 *
 * The early theme bootstrap lives inline in each page's <head> (so the
 * saved theme applies before first paint); this file only handles clicks.
 */
(function () {
  var root = document.documentElement;

  /* ---- theme toggle: data-theme on <html> overrides prefers-color-scheme ---- */
  function current() {
    var t = root.getAttribute('data-theme');
    if (t) return t;
    return window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  }
  [].forEach.call(document.querySelectorAll('[data-theme-toggle]'), function (b) {
    b.addEventListener('click', function () {
      var next = current() === 'dark' ? 'light' : 'dark';
      root.setAttribute('data-theme', next);
      try { localStorage.setItem('awr-theme', next); } catch (e) {}
    });
  });

  /* ---- copy buttons: <button class="copy" data-copy="ID"> copies element #ID,
         minus any prompt spans (.p) ---- */
  function copyText(txt, btn) {
    var l = btn.querySelector('.lbl');
    var orig = l ? l.textContent : '';
    function ok() {
      btn.classList.add('done');
      if (l) l.textContent = 'Copied';
      btn.setAttribute('aria-label', 'Copied');
      setTimeout(function () {
        btn.classList.remove('done');
        if (l) l.textContent = orig;
        btn.setAttribute('aria-label', 'Copy');
      }, 1400);
    }
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = txt; ta.setAttribute('readonly', '');
      ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); ok(); } catch (e) {}
      document.body.removeChild(ta);
    }
    if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(txt).then(ok, fallback);
    else fallback();
  }
  document.addEventListener('click', function (e) {
    var b = e.target.closest ? e.target.closest('.copy[data-copy]') : null;
    if (!b) return;
    var src = document.getElementById(b.getAttribute('data-copy'));
    if (!src) return;
    var clone = src.cloneNode(true);
    [].forEach.call(clone.querySelectorAll('.p'), function (n) { n.parentNode.removeChild(n); });
    copyText(clone.textContent.replace(/\s+$/, ''), b);
  });
  [].forEach.call(document.querySelectorAll('.copy[data-copy]'), function (b) {
    if (!b.hasAttribute('aria-label')) b.setAttribute('aria-label', 'Copy');
  });

  /* ---- narrow-layout menu: close after picking a link, or on Escape ---- */
  var menu = document.querySelector('.menu');
  if (menu) {
    menu.addEventListener('click', function (e) { if (e.target.closest('a')) menu.removeAttribute('open'); });
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') menu.removeAttribute('open'); });
  }

  /* ---- contents highlight: the .toc link of the last section whose top has
         scrolled above 35% of the viewport (none while above the first) ---- */
  var links = [].slice.call(document.querySelectorAll('.toc a[href^="#"]'));
  var targets = links.map(function (a) { return document.getElementById(a.getAttribute('href').slice(1)); });
  if (links.length) {
    var queued = false;
    var spy = function () {
      queued = false;
      var line = window.innerHeight * 0.35, best = -1;
      targets.forEach(function (t, i) { if (t && t.getBoundingClientRect().top <= line) best = i; });
      links.forEach(function (a, i) { a.classList.toggle('act', i === best); });
    };
    var queue = function () { if (!queued) { queued = true; requestAnimationFrame(spy); } };
    window.addEventListener('scroll', queue, { passive: true });
    window.addEventListener('resize', queue);
    spy();
  }
})();
