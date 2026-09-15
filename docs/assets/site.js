/*
 * Project website behaviour: theme toggle (same localStorage key as the
 * generated report, "awr-theme"), top-bar scrollspy, the narrow-layout
 * menu, and copy buttons on code blocks.
 */
(function () {
  var doc = document, body = doc.body;

  // ---- theme (shared key with the generated report) ----
  var KEY = "awr-theme";
  function applyTheme(t) { body.classList.toggle("dark", t === "dark"); }
  try {
    var saved = localStorage.getItem(KEY);
    if (saved) applyTheme(saved);
    else if (window.matchMedia && matchMedia("(prefers-color-scheme: dark)").matches) applyTheme("dark");
  } catch (e) {}
  doc.querySelectorAll(".theme-icon-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      var dark = !body.classList.contains("dark");
      applyTheme(dark ? "dark" : "light");
      try { localStorage.setItem(KEY, dark ? "dark" : "light"); } catch (e) {}
    });
  });

  // ---- top bar: narrow-layout menu + scrollspy ----
  var bar = doc.querySelector(".topbar");
  if (bar) {
    var mb = bar.querySelector(".menu-btn"), links = bar.querySelector(".links");
    if (mb && links) {
      mb.addEventListener("click", function () {
        var open = links.classList.toggle("open");
        mb.setAttribute("aria-expanded", open ? "true" : "false");
      });
      links.addEventListener("click", function (e) {
        if (e.target.tagName === "A") { links.classList.remove("open"); mb.setAttribute("aria-expanded", "false"); }
      });
    }
    var spyLinks = [].slice.call(doc.querySelectorAll('.topbar .links a[href^="#"], .subnav a[href^="#"]'));
    var targets = spyLinks.map(function (a) { return doc.getElementById(a.getAttribute("href").slice(1)); });
    function spy() {
      var y = window.scrollY + 100;
      var bestId = null, bestTop = -Infinity;
      targets.forEach(function (t) { if (t && t.offsetTop <= y && t.offsetTop > bestTop) { bestTop = t.offsetTop; bestId = t.id; } });
      spyLinks.forEach(function (a) { a.classList.toggle("on", bestId !== null && a.getAttribute("href") === "#" + bestId); });
    }
    if (spyLinks.length) { spy(); window.addEventListener("scroll", spy, { passive: true }); window.addEventListener("resize", spy); }
  }

  // ---- copy buttons (data-copy = selector of the element whose text to copy) ----
  doc.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest(".copy-btn[data-copy]");
    if (!b) return;
    var el = doc.querySelector(b.getAttribute("data-copy"));
    if (!el) return;
    var txt = el.textContent.replace(/\n$/, "");
    function done() { var old = b.textContent; b.textContent = "Copied"; b.classList.add("done"); setTimeout(function () { b.textContent = old; b.classList.remove("done"); }, 1400); }
    function fallback(t) { var ta = doc.createElement("textarea"); ta.value = t; ta.style.position = "fixed"; ta.style.opacity = "0"; doc.body.appendChild(ta); ta.select(); try { doc.execCommand("copy"); } catch (x) {} doc.body.removeChild(ta); }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(done, function () { fallback(txt); done(); });
    else { fallback(txt); done(); }
  });
})();
