/*
 * Project website chrome behaviour — a small subset of what the report's
 * sql/00_params.sql wires: theme toggle (same localStorage key as the
 * report, "awr-theme"), rail scrollspy, the narrow-layout rail menu, and
 * copy buttons on code blocks.
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

  // ---- rail: narrow-layout menu + scrollspy ----
  var nav = doc.querySelector("nav.toc");
  if (nav) {
    var mb = nav.querySelector(".rail-menu-btn");
    if (mb) {
      mb.addEventListener("click", function () {
        var open = nav.classList.toggle("open");
        mb.setAttribute("aria-expanded", open ? "true" : "false");
      });
      nav.querySelectorAll(".rail-list a, .rail-foot a").forEach(function (a) {
        a.addEventListener("click", function () { nav.classList.remove("open"); mb.setAttribute("aria-expanded", "false"); });
      });
    }
    var links = [].slice.call(nav.querySelectorAll('.rail-list a[href^="#"]'));
    var cur = nav.querySelector(".rail-cur");
    var targets = links.map(function (a) { return doc.getElementById(a.getAttribute("href").slice(1)); });
    function spy() {
      var y = window.scrollY + 90, best = -1;
      for (var i = 0; i < targets.length; i++) { if (targets[i] && targets[i].offsetTop <= y) best = i; }
      links.forEach(function (a, i) { a.classList.toggle("on", i === best); });
      if (cur) cur.textContent = best >= 0 ? links[best].textContent.trim() : "";
    }
    if (links.length) { spy(); window.addEventListener("scroll", spy, { passive: true }); window.addEventListener("resize", spy); }
  }

  // ---- copy buttons (data-copy = selector of the element whose text to copy) ----
  doc.addEventListener("click", function (e) {
    var b = e.target.closest && e.target.closest(".copy-btn[data-copy]");
    if (!b) return;
    var el = doc.querySelector(b.getAttribute("data-copy"));
    if (!el) return;
    var txt = el.textContent.replace(/\n$/, "");
    function done() { var old = b.textContent; b.textContent = "Copied"; b.classList.add("done"); setTimeout(function () { b.textContent = old; b.classList.remove("done"); }, 1400); }
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(txt).then(done, function () { fallback(txt); done(); });
    else { fallback(txt); done(); }
    function fallback(t) { var ta = doc.createElement("textarea"); ta.value = t; ta.style.position = "fixed"; ta.style.opacity = "0"; doc.body.appendChild(ta); ta.select(); try { doc.execCommand("copy"); } catch (x) {} doc.body.removeChild(ta); }
  });
})();
