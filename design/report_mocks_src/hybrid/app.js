(function(){
'use strict';
var B = document.body;
B.classList.add('js');
var D = JSON.parse(document.getElementById('awr-data').textContent);
var $ = function(s, r){ return (r || document).querySelector(s); };
var $$ = function(s, r){ return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
var CUR = 12, MINUS = '−';
function esc(s){ return String(s == null ? '' : s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
function shown(el){ return !!el && el.getClientRects().length > 0; }
function reduced(){ return matchMedia('(prefers-reduced-motion: reduce)').matches; }

/* ------------------------------------------------ number formatting (mirrors build.py) */
function sig(v, d){ if (v === 0) return '0'; var dec = Math.max(0, d - 1 - Math.floor(Math.log10(Math.abs(v))));
  if (dec === 0) return Math.round(v).toLocaleString('en-US'); return v.toFixed(dec); }
function fv(v, u){
  if (v == null) return ['—', ''];
  var a = Math.abs(v);
  if (u === 'B/s'){ if (a >= 1e9) return [sig(v / 1e9, 4), 'GB/s']; if (a >= 1e6) return [sig(v / 1e6, 4), 'MB/s']; if (a >= 1e3) return [sig(v / 1e3, 4), 'kB/s']; return [sig(v, 4), 'B/s']; }
  if (a >= 1e9) return [sig(v / 1e9, 4) + 'G', u]; if (a >= 1e6) return [sig(v / 1e6, 4) + 'M', u]; if (a >= 1e4) return [sig(v / 1e3, 4) + 'k', u];
  return [sig(v, 4).replace('-', MINUS), u];
}
function fvs(v, u){ var x = fv(v, u); return x[0] + (x[1] ? (x[1].charAt(0) === '/' ? '' : ' ') + x[1] : ''); }
function fnum(v){ return fv(v, '')[0]; }
function den(r){ return Math.max(r.sd || 0, 0.02 * Math.abs(r.mu || 0)); }
function delta(cur, mu){ if (cur == null || mu == null || mu === 0) return '—'; var q = cur / mu;
  if (q >= 2) return '▲ ×' + (q < 100 ? q.toFixed(1) : Math.round(q)); var p = (cur - mu) / Math.abs(mu) * 100;
  return (p >= 0 ? '▲ ' : '▼ ') + Math.abs(p).toFixed(1) + '%'; }
function zt(r){ if (r.zc) return '>+99σ'; if (r.z == null) return '—'; return (r.z >= 0 ? '+' : MINUS) + Math.abs(r.z).toFixed(1) + 'σ'; }
var SEVW = {large:'large finding', moderate:'moderate finding', typical:'normal', improved:'improved', flat:'flat baseline', 'n/a':'not scored', insufficient:'too little history'};
function nums(s){ return s.split(',').map(function(x){ return x === '' ? null : +x; }); }
function cssNum(el, n, d){ var v = parseFloat(getComputedStyle(el).getPropertyValue(n)); return isNaN(v) ? d : v; }
function mk(tag, cls, parent){ var e = document.createElement(tag); if (cls) e.className = cls; if (parent) parent.appendChild(e); return e; }

/* ------------------------------------------------ 1. the 13-window component: bars, zone, severity dot */
function zoneOf(r){ if (r.mu == null) return null; var d = den(r); return [Math.max(0, r.mu - 2 * d), r.mu + 2 * d, Math.max(0, r.mu - d), r.mu + d, r.mu]; }
function sizeBars(row){
  var r = D.rows[row.dataset.k]; if (!r) return;
  var vals = r.v, z = zoneOf(r), sev = r.tw ? '' : r.sev;
  var wg = row.closest('.wg'), bare = wg.classList.contains('bare'), inTL = !!row.closest('#tl');
  var have = vals.filter(function(v){ return v != null; });
  var max = Math.max.apply(null, have.concat(z ? [z[1]] : [])) || 1;
  var bh = cssNum(row, '--bh', 24), bb = cssNum(row, '--bb', 4);
  var y = function(v){ return v / max * bh; };
  $$('.c', row).forEach(function(c, k){
    $$('i.b,i.sd,i.z1,i.z2,i.mn,i.base', c).forEach(function(x){ x.remove(); });
    if (z && (!inTL || k === CUR)){
      var z2 = mk('i', 'z2', c); z2.style.bottom = (bb + y(z[0])) + 'px'; z2.style.height = Math.max(1, y(z[1] - z[0])) + 'px';
      var z1 = mk('i', 'z1', c); z1.style.bottom = (bb + y(z[2])) + 'px'; z1.style.height = Math.max(1, y(z[3] - z[2])) + 'px';
      var mn = mk('i', 'mn', c); mn.style.bottom = (bb + y(z[4])) + 'px';
    }
    if (bare) mk('i', 'base', c);
    var v = vals[k]; if (v == null) return;
    var h = Math.max(1.5, y(v));
    var b = mk('i', 'b', c); b.style.height = h + 'px';
    if (k === CUR && (sev === 'large' || sev === 'moderate')){ var d = mk('i', 'sd s-' + sev, c); d.style.bottom = (bb + h) + 'px'; }
  });
}
/* stacked activity columns (ASH per compared hour) */
function sizeAsh(row){
  var A = JSON.parse(row.dataset.ash), bh = cssNum(row, '--bh', 148), bb = cssNum(row, '--bb', 6), GAP = 2;
  $$('.c', row).forEach(function(c, k){
    $$('.stk,.gline,.dl', c).forEach(function(x){ x.remove(); });
    A.ticks.forEach(function(t){ var g = mk('i', 'gline', c); g.style.bottom = (bb + t / A.max * bh) + 'px'; });
    var stk = mk('div', 'stk', c), y = 0, segs = [];
    A.cls.forEach(function(name, i){
      var v = A.v[i][k], h = v / A.max * bh; if (h < 0.4) return;
      var s = mk('i', '', stk); s.style.background = A.col[i]; s.style.bottom = y + 'px';
      s.style.height = Math.max(0.6, h - (h > 4 ? GAP : 0)) + 'px';
      segs.push({name: name, v: v, mid: y + h / 2}); y += h;
    });
    if (k === CUR){
      var last = -99;
      ['CPU', 'User I/O'].forEach(function(n){
        var s = segs.filter(function(x){ return x.name === n; })[0]; if (!s) return;
        var pos = Math.max(s.mid, last + 16); last = pos;
        var d = mk('span', 'dl', c); d.innerHTML = '<i class="sw" style="--sw:' + A.col[A.cls.indexOf(n)] + '"></i>' + s.v.toFixed(1); d.title = n; d.style.bottom = (bb + pos) + 'px';
      });
    }
  });
  var ax = $('.axn', row);
  if (ax){ ax.innerHTML = ''; [0].concat(A.ticks).forEach(function(t){ var i = mk('i', '', ax); i.textContent = t; i.style.bottom = (bb + t / A.max * bh) + 'px'; }); }
}
/* day profile: grey bars, Current hour in the accent, a dot on a flagged hour */
function sizeDay(){
  $$('.dpr[data-v]').forEach(function(row){
    var v = nums(row.dataset.v), mu = nums(row.dataset.mu), sev = row.dataset.sev.split(',');
    var max = Math.max.apply(null, v.concat(mu)) || 1, bh = 22;
    $$('.dc', row).forEach(function(c, i){
      $$('i', c).forEach(function(x){ x.remove(); });
      var h = Math.max(1.5, v[i] / max * bh);
      var b = mk('i', 'b', c); b.style.height = h + 'px';
      var t = mk('i', 'mu', c); t.style.bottom = (5 + mu[i] / max * bh) + 'px';
      if (sev[i] === 'l' || sev[i] === 'm'){ var d = mk('i', 'sd s-' + (sev[i] === 'l' ? 'large' : 'moderate'), c); d.style.bottom = (5 + h + 2) + 'px'; }
    });
  });
}
/* the same grammar, micro: 13 bars in a table cell */
function microStrip(td){
  var r = D.rows[td.dataset.k]; if (!r) return;
  var W = 92, H = 22, n = r.v.length, gap = 2, cw = (W - gap * n) / (n + 0.6);
  var d = den(r), lo = Math.max(0, r.mu - 2 * d), hi = r.mu + 2 * d;
  var have = r.v.filter(function(x){ return x != null; }), max = Math.max.apply(null, have.concat([hi])) || 1;
  var Y = function(v){ return H - 1 - (H - 3) * v / max; };
  var s = '<svg class="mw" width="' + W + '" height="' + H + '" viewBox="0 0 ' + W + ' ' + H + '" aria-hidden="true">';
  if (r.mu != null) s += '<rect class="z2" x="0" y="' + Y(hi).toFixed(1) + '" width="' + W + '" height="' + Math.max(1, Y(lo) - Y(hi)).toFixed(1) + '" rx="1"/>';
  var x = 0;
  r.v.forEach(function(v, k){
    var w = k === CUR ? cw * 1.6 : cw;
    if (v != null){ var y = Y(v); s += '<rect class="b' + (k === CUR ? ' cur' : '') + '" x="' + x.toFixed(1) + '" y="' + y.toFixed(1) + '" width="' + w.toFixed(1) + '" height="' + Math.max(1, H - 1 - y).toFixed(1) + '" rx="1"/>'; }
    x += w + gap;
  });
  s += '</svg>';
  td.innerHTML = s;
  td.title = r.n + ': ' + r.v.map(function(v, k){ return (k === CUR ? 'Current ' : D.w[k] + ' ') + fnum(v); }).slice(-4).join(', ');
}

/* ------------------------------------------------ 2. flags on column boundaries, per 13-window instance */
function markFlags(wg){
  D.mk.forEach(function(m){ $$('[data-w="' + m.w + '"]', wg).forEach(function(c){ if (c.classList.contains('c') || c.classList.contains('h')) c.classList.add('mk'); }); });
}
function layoutFlags(wg){
  var fl = $('.flags', wg); if (!fl || !shown(fl)) return;
  fl.innerHTML = '';
  var base = fl.getBoundingClientRect().left, width = fl.clientWidth, TH = 17;
  var tiers = [[], []], narrow = width < 520;
  var anchor = function(w){ return $$('[data-w="' + w + '"]', wg).filter(function(e){ return !e.closest('.flags'); })[0]; };
  D.mk.forEach(function(m){
    var ref = anchor(m.w); if (!ref) return;
    var x = ref.getBoundingClientRect().left - base;
    var labels = narrow ? [m.s] : [m.l, m.s], cands = [];
    labels.forEach(function(l){ cands.push([l, 0]); }); labels.forEach(function(l){ cands.push([l, 1]); });
    cands.some(function(cd){
      for (var t = 0; t < tiers.length; t++){
        var f = mk('div', 'flag', fl); f.textContent = cd[0]; f.style.left = x + 'px'; f.style.top = (2 + t * TH) + 'px';
        f.title = m.l + ', ' + m.t + '. Between the ' + D.w[m.w - 1] + ' and ' + (m.w === CUR ? 'Current' : D.w[m.w]) + ' windows';
        var w = f.offsetWidth, x0 = x - 2, x1 = x + w + 6;
        if (cd[1]){ f.classList.add('end'); f.style.left = (x - w) + 'px'; x0 = x - w - 6; x1 = x + 2; }
        var clash = tiers[t].some(function(r){ return x0 < r[1] && x1 > r[0]; }) || x1 > width + 1 || x0 < -1;
        if (!clash){ tiers[t].push([x0, x1]); var p = mk('i', 'pole', fl); p.style.left = (x - 1.5) + 'px'; p.style.top = (2 + t * TH) + 'px'; return true; }
        fl.removeChild(f);
      }
      return false;
    });
  });
}
function fitWG(wg){
  if (!shown(wg)) return;
  var c = $('.r:not(.fr) .c[data-w="0"], .r .h[data-w="0"]', wg);
  if (c) wg.classList.toggle('tight', c.getBoundingClientRect().width < 42);
  layoutFlags(wg);
}
function redrawVisible(scope){
  $$('[data-wg]', scope).forEach(fitWG);
  if (scope && scope.matches && scope.matches('[data-wg]')) fitWG(scope);
  drawAsh();
  syncCap();
}

/* ------------------------------------------------ 3. hover a column (Timeline and hero strip), tooltip, pin */
var tip = $('#tip');
var hov = [];
for (var k = 0; k < 13; k++){
  hov.push('body[data-hw="' + k + '"] .wg.hov .c[data-w="' + k + '"],body[data-hw="' + k + '"] .wg.hov .h[data-w="' + k + '"]{background-image:linear-gradient(var(--hov),var(--hov))}');
  hov.push('body[data-hw="' + k + '"] .wg.hov .c[data-w="' + k + '"] .v,body[data-pw="' + k + '"] #tl .c[data-w="' + k + '"] .v{opacity:1!important}');
  hov.push('body[data-pw="' + k + '"] #tl .c[data-w="' + k + '"],body[data-pw="' + k + '"] #tl .h[data-w="' + k + '"]{background-image:linear-gradient(var(--pin),var(--pin))}');
}
mk('style', '', document.head).textContent = hov.join('\n');
$$('#tl, #s-strip .wg').forEach(function(w){ w.classList.add('hov'); });
function setHW(w){ if (w == null) delete B.dataset.hw; else B.dataset.hw = w; }
function tipHTML(cell){
  var row = cell.closest('.r'); if (!row || !row.dataset.name) return '';
  var k = +cell.dataset.w, head = '<b>' + esc(row.dataset.name) + '</b><br><span class="tm">' + D.full[k] + (k === CUR ? ', Current' : ', ' + D.off[k]) + '</span><br>';
  if (row.dataset.ash){
    var A = JSON.parse(row.dataset.ash), s = '', tot = 0;
    A.cls.forEach(function(n, i){ tot += A.v[i][k]; });
    A.cls.forEach(function(n, i){ if (A.v[i][k] >= 0.05) s += '<br>' + n + ' ' + A.v[i][k].toFixed(2); });
    return head + '<b>' + tot.toFixed(1) + '</b> active sessions' + s;
  }
  if (row.classList.contains('p')) return head + '<b>' + esc(cell.dataset.pv) + '</b>';
  var v = $('.v', cell);
  if (!v || v.classList.contains('nil')) return head + '<span class="tm">not in the top 10 in this window</span>';
  var g = $('.glf', cell);
  return head + '<b>' + v.textContent + '</b> ' + esc(row.dataset.unit || '') + (g ? '<br>' + esc(g.title) : '');
}
function placeTip(e){
  var x = e.clientX + 14, y = e.clientY + 16, w = tip.offsetWidth, h = tip.offsetHeight;
  if (x + w > innerWidth - 8) x = e.clientX - w - 12;
  if (y + h > innerHeight - 8) y = e.clientY - h - 12;
  tip.style.left = Math.max(8, x) + 'px'; tip.style.top = Math.max(8, y) + 'px';
}
document.addEventListener('mouseover', function(e){
  var t = e.target; if (!t.closest) return;
  var c = t.closest('.wg .c[data-w]'), h = t.closest('.wg.hov .h[data-w]');
  var hw = (c && c.closest('.wg.hov')) ? c.dataset.w : (h ? h.dataset.w : null);
  setHW(hw);
  if (c && !c.closest('.r.gh2')){ var s = tipHTML(c); if (s){ tip.innerHTML = s; tip.hidden = false; placeTip(e); return; } }
  var dc = t.closest('.dpr[data-v] .dc');
  if (dc){ var row = dc.closest('.dpr'), i = $$('.dc', row).indexOf(dc), v = nums(row.dataset.v)[i], mu = nums(row.dataset.mu)[i], sv = row.dataset.sev.split(',')[i];
    tip.innerHTML = '<b>' + esc(row.dataset.name) + '</b><br><span class="tm">hour starting ' + D.hrs[i] + (i === 23 ? ', the Current window' : '') + '</span><br><b>' + fnum(v) + '</b> vs prior-day mean ' + fnum(mu) + (sv === 'l' ? '<br>large' : sv === 'm' ? '<br>moderate' : '');
    tip.hidden = false; placeTip(e); return; }
  tip.hidden = true;
});
document.addEventListener('mousemove', function(e){ if (!tip.hidden) placeTip(e); }, {passive: true});
document.addEventListener('mouseleave', function(){ setHW(null); tip.hidden = true; });

var gutTitle = $('#gut-title'), gutSub = $('#gut-sub');
function ratioTxt(cur, p){ return delta(cur, p); }
function pin(w){
  var same = B.dataset.pw === String(w);
  $$('#tl .ruler .h').forEach(function(h){ h.setAttribute('aria-pressed', 'false'); });
  $$('#tl .r.bars .g .d1').forEach(function(d){ if (d.dataset.orig != null) d.textContent = d.dataset.orig; });
  if (same || w == null || +w === CUR){
    delete B.dataset.pw; gutTitle.textContent = 'vs prior mean'; gutSub.textContent = 'click a date to pin'; return;
  }
  B.dataset.pw = w;
  $('#tl .ruler .h[data-w="' + w + '"]').setAttribute('aria-pressed', 'true');
  $$('#tl .r.bars[data-k]').forEach(function(row){
    var d = $('.g .d1', row); if (!d || !D.rows[row.dataset.k]) return;
    var v = D.rows[row.dataset.k].v;
    if (d.dataset.orig == null) d.dataset.orig = d.textContent;
    d.textContent = ratioTxt(v[CUR], v[w]) + ' vs ' + D.w[w];
  });
  gutTitle.innerHTML = 'vs ' + D.w[w] + ' <button type="button" id="unpin" aria-label="Clear pinned window">clear</button>';
  gutSub.textContent = 'band stays vs prior mean';
  $('#unpin').addEventListener('click', function(){ pin(null); });
}
$$('#tl .ruler .h').forEach(function(h){ h.addEventListener('click', function(){ pin(h.dataset.w); }); });
document.addEventListener('keydown', function(e){ if (e.key === 'Escape'){ if (B.dataset.pw) pin(null); B.classList.remove('rail-open'); } });

/* scroll sync: the sticky ruler follows the grid body; lane captions stay in view */
var gbody = $('#gbody'), ruler = $('#ruler'), gin = $('#gin');
function syncCap(){ if (!gbody) return; gin.style.setProperty('--sl', gbody.scrollLeft + 'px'); gin.style.setProperty('--vw', gbody.clientWidth + 'px'); }
if (gbody) gbody.addEventListener('scroll', function(){ ruler.scrollLeft = gbody.scrollLeft; syncCap(); }, {passive: true});
function startAtCurrent(){
  [gbody, $('#dpscroll')].forEach(function(s){ if (s && s.scrollWidth > s.clientWidth + 2) s.scrollLeft = s.scrollWidth; });
  if (gbody) ruler.scrollLeft = gbody.scrollLeft; syncCap();
}

/* ------------------------------------------------ 4. lanes, (i), tabs, expanders */
$$('.lt2').forEach(function(b){
  b.addEventListener('click', function(){ var lane = document.getElementById(b.dataset.lane); var open = lane.classList.toggle('closed') === false; b.setAttribute('aria-expanded', String(open)); });
});
$$('.xpb').forEach(function(b){
  b.addEventListener('click', function(){ document.getElementById(b.dataset.for).classList.add('showmore'); b.setAttribute('aria-expanded', 'true'); redrawVisible(document.getElementById(b.dataset.for).closest('[data-wg]')); });
});
document.addEventListener('click', function(e){
  var b = e.target.closest && e.target.closest('.info'); if (!b) return;
  e.preventDefault(); e.stopPropagation();
  var d = b.closest('details'); if (d && !d.open) d.open = true;
  var p = document.getElementById(b.getAttribute('aria-controls')); var o = b.getAttribute('aria-expanded') === 'true';
  b.setAttribute('aria-expanded', String(!o)); p.hidden = o;
}, true);
document.addEventListener('click', function(e){
  var b = e.target.closest && e.target.closest('[role="tab"]'); if (!b) return;
  var list = b.closest('[role="tablist"]');
  $$('[role="tab"]', list).forEach(function(t){ var on = t === b; t.setAttribute('aria-selected', String(on)); document.getElementById(t.getAttribute('aria-controls')).hidden = !on; });
  redrawVisible(document.getElementById(b.getAttribute('aria-controls')));
});

var CHEV_FLAGS = '<div class="r fr t2" aria-hidden="true"><div class="flags"></div></div>';
function wgHTML(r, key){
  var h = '<div class="wg bare allv" data-wg>' + CHEV_FLAGS;
  h += '<div class="r bars" data-k="' + esc(key) + '" data-name="' + esc(r.n) + '" data-unit="' + esc(r.u) + '">';
  r.v.forEach(function(v, k){ h += '<div class="c' + (k === CUR ? ' cur' : '') + '" data-w="' + k + '">' + (v == null ? '<span class="v nil">–</span>' : '<span class="v">' + fnum(v) + '</span>') + '</div>'; });
  h += '</div><div class="r dr" aria-hidden="true">';
  D.w.forEach(function(w, k){ h += '<div class="h' + (k === CUR ? ' cur' : '') + (k % 4 === 0 ? ' keep' : '') + '" data-w="' + k + '"><span class="hd">' + w + '</span></div>'; });
  return h + '</div></div>';
}
function detail(r, k){
  var d = den(r);
  var facts = '<dl><dt>Current</dt><dd>' + fvs(r.v[CUR], r.u) + '</dd><dt>Prior mean</dt><dd>' + fvs(r.mu, r.u) + '</dd><dt>Prior σ</dt><dd>' + fvs(r.sd, r.u) + (d > (r.sd || 0) ? ' (floored at 2% of mean)' : '') + '</dd>' +
    '<dt>Windows</dt><dd>' + r.nw + ' prior</dd><dt>z</dt><dd>' + zt(r) + ' (' + (SEVW[r.sev] || r.sev) + (r.imm ? ', immaterial' : '') + ')</dd>' + (r.f || '') + '</dl>';
  return '<div class="xp"><div class="cc">' + wgHTML(r, k) + (r.l || '') + '</div>' + facts + (r.x || (r.q && D.sqlt[r.q] ? '<div class="sqltext">' + esc(D.sqlt[r.q]) + '</div>' : '')) + '</div>';
}
function toggleRow(btn){
  var tr = btn.closest('tr'), open = btn.getAttribute('aria-expanded') === 'true';
  if (open){ var nx = tr.nextElementSibling; if (nx && nx.classList.contains('xr')) nx.remove(); btn.setAttribute('aria-expanded', 'false'); return; }
  var r = D.rows[btn.dataset.k]; if (!r) return;
  var x = document.createElement('tr'); x.className = 'xr'; x.innerHTML = '<td colspan="' + tr.children.length + '">' + detail(r, btn.dataset.k) + '</td>';
  tr.after(x); btn.setAttribute('aria-expanded', 'true');
  $$('.r.bars', x).forEach(sizeBars); $$('[data-wg]', x).forEach(markFlags); redrawVisible(x);
}
document.addEventListener('click', function(e){ var b = e.target.closest && e.target.closest('.xb'); if (b) toggleRow(b); });
function setMore(btn, open){
  var n = btn.dataset.n; btn.setAttribute('aria-expanded', String(open));
  btn.innerHTML = '<i class="dotk typical" aria-hidden="true"></i>' + (open ? 'Hide the ' + n + ' normal rows' : 'Show ' + n + ' normal rows');
  var tb = $('#' + btn.dataset.for + ' tbody.nrm'); if (tb) tb.classList.toggle('open', open);
}
document.addEventListener('click', function(e){ var b = e.target.closest && e.target.closest('.more'); if (b) setMore(b, b.getAttribute('aria-expanded') !== 'true'); });
document.addEventListener('click', function(e){
  var th = e.target.closest && e.target.closest('th[data-sort]'); if (!th) return;
  var t = th.closest('table'), k = th.dataset.sort, dir = th.getAttribute('aria-sort') === 'descending' ? 'ascending' : 'descending';
  $$('th[data-sort]', t).forEach(function(x){ x.removeAttribute('aria-sort'); }); th.setAttribute('aria-sort', dir);
  var m = dir === 'ascending' ? 1 : -1, nrm = $('tbody.nrm', t);
  $$('tbody.grp', t).sort(function(a, b){ return k === 'name' ? m * a.dataset.name.localeCompare(b.dataset.name) : m * (parseFloat(a.dataset[k]) - parseFloat(b.dataset[k])); })
    .forEach(function(g){ t.insertBefore(g, nrm); });
});

/* ------------------------------------------------ 5. ASH over the whole span (All sections), B's smoothed chart */
var MKT = D.mk.map(function(m){ return m; });
var cvs = document.createElement('canvas').getContext('2d');
function tw(t){ cvs.font = '11px ui-sans-serif, -apple-system, "Segoe UI", Inter, Roboto, system-ui, sans-serif'; return cvs.measureText(t).width; }
var MKS = [['Release 4.0', '2026-06-30 22:00'], ['Hotfix 4.0.1', '2026-07-03 09:00'], ['RU 19.28 patch', '2026-07-21 01:00'], ['Release 4.1', '2026-08-11 22:00'], ['Release 4.2', '2026-09-08 22:00']];
var SER = [['CPU', 'wc-CPU', '#3FB344'], ['User I/O', 'wc-UIO', '#4A90D9'], ['Network', 'wc-NET', '#967259'], ['Commit', 'wc-COM', '#E89B40'], ['Other classes', 'wc-OTH', '']];
var ashLgd = $('#ash-lgd');
if (ashLgd) ashLgd.innerHTML = SER.map(function(s){ return '<span><i class="sw" style="--sw:' + (s[2] || 'var(--other)') + '"></i>' + s[0] + '' + '</span>'; }).join('') +
  '<span><svg width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="4" fill="var(--surface)" stroke="var(--ink-2)" stroke-width="1.5"/></svg>prior 09:00</span>' +
  '<span><svg width="12" height="12" aria-hidden="true"><circle cx="6" cy="6" r="4.5" fill="var(--acc)"/></svg>Current hour</span>';
function drawAsh(){
  var svg = $('#ash-svg'), wrap = $('#ashw'); if (!svg || !shown(wrap)) return;
  var A = D.ash, Wd = Math.max(300, wrap.clientWidth); if (svg._w === Wd) return; svg._w = Wd;
  var narrow = Wd < 600, padL = narrow ? 28 : 36, padR = narrow ? 8 : 12, top = 44, ph = narrow ? 160 : 210, H = top + ph + 30;
  svg.setAttribute('viewBox', '0 0 ' + Wd + ' ' + H); svg.setAttribute('height', H);
  var P = function(s){ return Date.parse(s.replace(' ', 'T') + ':00Z'); };
  var T = A.t.map(P), tc = T.map(function(t, i){ return t + (i === T.length - 1 ? 0.5 : 3) * 36e5; });
  var WIN = A.win.map(P), t0 = P('2026-06-18 09:00'), t1 = P('2026-09-10 10:00');
  var X = function(t){ return padL + (Wd - padL - padR) * (t - t0) / (t1 - t0); };
  var sm = A.series.map(function(s){ return s.vals.map(function(v, i, a){ var lo = Math.max(0, i - 2), hi = Math.min(a.length - 1, i + 1), sum = 0; for (var k = lo; k <= hi; k++) sum += a[k]; return sum / (hi - lo + 1); }); });
  var n = T.length, acc = new Array(n).fill(0);
  var layers = sm.map(function(vals){ var lo = acc.slice(); acc = acc.map(function(a, i){ return a + vals[i]; }); return {lo: lo, hi: acc.slice()}; });
  var ymax = Math.ceil(Math.max.apply(null, acc.concat(A.wtot)) / 5) * 5, Y = function(v){ return top + ph - ph * v / ymax; };
  var s = '';
  for (var v = 0; v <= ymax; v += 5) s += '<line class="gl" x1="' + padL + '" x2="' + (Wd - padR) + '" y1="' + Y(v) + '" y2="' + Y(v) + '"/><text class="at" x="' + (padL - 6) + '" y="' + (Y(v) + 4) + '" text-anchor="end">' + v + '</text>';
  layers.forEach(function(L, k){ var d = 'M' + X(tc[0]).toFixed(1) + ' ' + Y(L.hi[0]).toFixed(1);
    for (var i = 1; i < n; i++) d += 'L' + X(tc[i]).toFixed(1) + ' ' + Y(L.hi[i]).toFixed(1);
    for (i = n - 1; i >= 0; i--) d += 'L' + X(tc[i]).toFixed(1) + ' ' + Y(L.lo[i]).toFixed(1);
    s += '<path class="ar ' + SER[k][1] + '" d="' + d + 'Z"/>'; });
  var cx = X(WIN[12] + 18e5), cw = Math.max(6, X(WIN[12] + 36e5) - X(WIN[12]));
  s += '<rect class="curband" x="' + (cx - cw / 2) + '" y="' + top + '" width="' + cw + '" height="' + ph + '"/>';
  s += '<line class="ax" x1="' + padL + '" x2="' + (Wd - padR) + '" y1="' + (top + ph) + '" y2="' + (top + ph) + '"/>';
  var ends = [[], []];
  MKS.forEach(function(m){ var x = X(P(m[1])), lab = narrow ? (D.mk.filter(function(q){ return q.l === m[0]; })[0] || {s: m[0]}).s : m[0], w = tw(lab) + 12;
    var x0 = x, anchor = 'start'; if (x0 + w > Wd - padR){ x0 = x - w; anchor = 'end'; }
    var L = 0; while (L < 1 && ends[L].some(function(r){ return x0 < r[1] + 6 && x0 + w > r[0] - 6; })) L++;
    ends[L].push([x0, x0 + w]); var y = 4 + L * 18;
    s += '<line class="cfl" x1="' + x + '" x2="' + x + '" y1="' + (y + 16) + '" y2="' + (top + ph) + '"/><line class="cf" x1="' + x + '" x2="' + x + '" y1="' + y + '" y2="' + (y + 16) + '"/>' +
      '<rect class="cfh" x="' + (anchor === 'start' ? x + 1 : x0) + '" y="' + y + '" width="' + (w - 1) + '" height="16" rx="2"/>' +
      '<text class="cft" x="' + (anchor === 'start' ? x + 6 : x - 6) + '" y="' + (y + 12) + '" text-anchor="' + anchor + '"><title>' + esc(m[0]) + '</title>' + esc(lab) + '</text>'; });
  WIN.forEach(function(w, i){ var x = X(w + 18e5), cur = i === 12; s += '<line class="wt' + (cur ? ' cur' : '') + '" x1="' + x + '" x2="' + x + '" y1="' + (top + ph + 1) + '" y2="' + (top + ph + (cur ? 9 : 6)) + '"/>'; });
  WIN.forEach(function(w, i){ var x = X(w + 18e5), cur = i === 12; s += '<circle class="wd' + (cur ? ' cur' : '') + '" cx="' + x + '" cy="' + Y(A.wtot[i]) + '" r="' + (cur ? 5.5 : 4) + '"><title>' + (cur ? 'Current' : D.w[i]) + ' 09:00–10:00: ' + A.wtot[i].toFixed(1) + ' AAS</title></circle>'; });
  s += '<text class="at b" x="' + (cx - 10) + '" y="' + (Y(A.wtot[12]) + 4) + '" text-anchor="end">' + A.wtot[12].toFixed(1) + '</text>';
  s += '<text class="at" x="' + padL + '" y="' + (top + ph + 24) + '">18 Jun</text>';
  var cl = narrow ? 'Current' : 'Current, 10 Sep 09:00', clw = tw(cl) + 4;
  [['2026-07-01', 'Jul'], ['2026-08-01', 'Aug'], ['2026-09-01', 'Sep']].forEach(function(m){ var x = X(P(m[0] + ' 00:00')); if (x + tw(m[1]) > cx - clw - 4) return; s += '<line class="ax" x1="' + x + '" x2="' + x + '" y1="' + (top + ph) + '" y2="' + (top + ph + 4) + '"/><text class="at" x="' + (x + 3) + '" y="' + (top + ph + 24) + '">' + m[1] + '</text>'; });
  s += '<text class="at b" x="' + (Wd - padR) + '" y="' + (top + ph + 24) + '" text-anchor="end">' + cl + '</text>';
  svg.innerHTML = s;
}

/* ------------------------------------------------ 6. views: Summary / Timeline / All sections */
var VIEWS = {summary: 'vs', timeline: 'vt', all: 'va'};
var libDefault = $$('#lib > details').map(function(d){ return d.open; }), libState = null;
var findMore = $('.more[data-for="t-find"]');
function setView(v, persist){
  if (!VIEWS[v]) v = 'summary';
  var prev = B.dataset.view;
  B.classList.remove('vs', 'vt', 'va'); B.classList.add(VIEWS[v]); B.dataset.view = v;
  $$('.topbar .seg [data-v]').forEach(function(b){ b.setAttribute('aria-pressed', String(b.dataset.v === v)); });
  var dets = $$('#lib > details');
  if (v === 'all' && prev !== 'all'){ libState = prev ? dets.map(function(d){ return d.open; }) : libDefault; dets.forEach(function(d){ d.open = true; }); if (findMore) setMore(findMore, true); }
  if (prev === 'all' && v !== 'all'){ dets.forEach(function(d, i){ d.open = (libState || libDefault)[i]; }); if (findMore) setMore(findMore, false); }
  if (persist){
    try { localStorage.setItem('awr-view', v); } catch (e) {}
    if (/view=/.test(location.hash)) try { history.replaceState(null, '', location.pathname + location.search); } catch (e) {}
  }
  if (v !== 'timeline' && B.dataset.pw) pin(null);
  redrawVisible();
  if (v === 'timeline') startAtCurrent();
  dimRail(); spy();
}
function viewOf(el){
  var w = el.closest('.vw'); if (!w) return null;
  var cur = B.dataset.view, has = function(v){ return w.classList.contains('in-' + v.charAt(0)); };
  if (has(cur)) return cur;
  return has('summary') ? 'summary' : has('timeline') ? 'timeline' : 'all';
}
$$('.topbar .seg [data-v]').forEach(function(b){ b.addEventListener('click', function(){ setView(b.dataset.v, true); window.scrollTo({top: 0, behavior: 'auto'}); }); });

function goTo(el, flash){
  if (!el) return;
  var v = viewOf(el); if (v && v !== B.dataset.view) setView(v, true);
  var d = el.closest('details'); if (d && !d.open) d.open = true;
  if (el.tagName === 'DETAILS') el.open = true;
  var lane = el.closest('.lane'); if (lane && lane.classList.contains('closed')) $('.lt2', lane).click();
  if (el.classList.contains('more') && lane) lane.classList.add('showmore');
  redrawVisible();
  requestAnimationFrame(function(){
    el.scrollIntoView({behavior: reduced() ? 'auto' : 'smooth', block: 'start'});
    if (el.closest('#tl') && gbody && gbody.scrollWidth > gbody.clientWidth + 2){ gbody.scrollLeft = gbody.scrollWidth; }
    if (flash){ el.classList.remove('flash'); void el.offsetWidth; el.classList.add('flash'); }
  });
}
document.addEventListener('click', function(e){
  var a = e.target.closest && e.target.closest('a[href^="#"]'); if (!a) return;
  var j = a.dataset.jump;
  if (j){ e.preventDefault(); setView('timeline', true); goTo(document.getElementById(j), true); B.classList.remove('rail-open'); return; }
  var id = a.getAttribute('href').slice(1); if (!id || id.indexOf('view=') === 0) return;
  var el = document.getElementById(id); if (!el) return;
  e.preventDefault(); goTo(el, false); B.classList.remove('rail-open');
  try { history.replaceState(null, '', '#' + id); } catch (err) {}
});

/* rail: dim links whose target is not in this view; scrollspy; mobile drawer */
var links = $$('.rail a');
function dimRail(){
  links.forEach(function(a){ var t = document.getElementById(a.getAttribute('href').slice(1)); a.classList.toggle('dim', !shown(t)); });
  $$('.rg').forEach(function(g){ g.classList.toggle('dim', $$('a', g).every(function(a){ return a.classList.contains('dim'); })); });
}
function spy(){
  var best = null, lim = cssNum(document.documentElement, '--tbar', 56) + 40;
  links.forEach(function(a){ if (a.classList.contains('dim')) return; var t = document.getElementById(a.getAttribute('href').slice(1)); if (!t) return;
    if (t.getBoundingClientRect().top <= lim) best = a; });
  if (!best) best = links.filter(function(a){ return !a.classList.contains('dim'); })[0];
  links.forEach(function(a){ a.classList.toggle('on', a === best); });
}
var st; addEventListener('scroll', function(){ if (st) return; st = requestAnimationFrame(function(){ st = null; spy(); }); }, {passive: true});
var mb = $('#menuBtn');
mb.addEventListener('click', function(){ var o = B.classList.toggle('rail-open'); mb.setAttribute('aria-expanded', String(o)); });

/* "N related metrics moved together": the family's rows from the findings table, same component */
function fillRelated(d){
  if (d._done) return; var g = $('#t-find tbody.grp[data-fam="' + d.dataset.fam + '"]'); if (!g) return; d._done = 1;
  var t = document.createElement('table'); t.className = 'bt compact rsp';
  var th = $('#t-find thead').cloneNode(true); $$('th', th).slice(-2).forEach(function(x){ x.remove(); }); $$('[data-sort]', th).forEach(function(x){ x.removeAttribute('data-sort'); });
  var tb = document.createElement('tbody');
  $$('tr:not(.fam):not(.xr)', g).forEach(function(tr){ var c = tr.cloneNode(true); $$('td.c-tr,td.c-x', c).forEach(function(x){ x.remove(); }); tb.appendChild(c); });
  t.appendChild(th); t.appendChild(tb); var w = $('.tw', d); w.innerHTML = ''; w.appendChild(t);
}
$$('details.rel[data-fam]').forEach(function(d){ d.addEventListener('toggle', function(){ if (d.open) fillRelated(d); }); });
/* details toggles and lane toggles may reveal a 13-window instance that measured zero */
$$('details').forEach(function(d){ d.addEventListener('toggle', function(){ if (d.open) redrawVisible(d); dimRail(); }); });

/* ------------------------------------------------ 7. theme, top-bar height, resize */
function setTheme(t){ B.classList.toggle('dark', t === 'dark'); B.classList.toggle('light', t === 'light'); try { localStorage.setItem('awr-theme', t); } catch (e) {} }
(function(){ var p = document.documentElement.getAttribute('data-theme-pref'); if (p){ B.classList.toggle('dark', p === 'dark'); B.classList.toggle('light', p === 'light'); } })();
$('#theme').addEventListener('click', function(){ var dark = B.classList.contains('dark') || (!B.classList.contains('light') && matchMedia('(prefers-color-scheme: dark)').matches); setTheme(dark ? 'light' : 'dark'); });
function measureBar(){ document.documentElement.style.setProperty('--tbar', $('#topbar').offsetHeight + 'px'); }
var rt; addEventListener('resize', function(){ clearTimeout(rt); rt = setTimeout(function(){ measureBar(); $$('#ash-svg').forEach(function(s){ s._w = 0; }); redrawVisible(); dimRail(); }, 120); });

/* ------------------------------------------------ boot */
$$('.wg .r.bars[data-k]').forEach(function(row){
  var r = D.rows[row.dataset.k]; if (!r) return;
  $$('.c[data-w]', row).forEach(function(c){ if ($('.v', c)) return; var v = r.v[+c.dataset.w];
    c.insertAdjacentHTML('afterbegin', v == null ? '<span class="v nil" aria-label="not present">\u2013</span>' : '<span class="v">' + fnum(v) + '</span>'); });
});
$$('.wg .r.bars').forEach(sizeBars);
$$('.wg .r.ash').forEach(sizeAsh);
sizeDay();
$$('td.c-tr[data-k]').forEach(microStrip);
$$('.bt td.c-x').forEach(function(td){
  var k = td.parentNode.querySelector('td.c-tr[data-k]'); if (!k || !D.rows[k.dataset.k]) return;
  td.innerHTML = '<button class="xb" type="button" aria-expanded="false" aria-label="Per-window values for ' + esc(D.rows[k.dataset.k].n) + '" data-k="' + esc(k.dataset.k) + '"></button>';
});
$$('[data-wg]').forEach(markFlags);
if (innerWidth < 640){ var mn = $('.mock'); if (mn) mn.removeAttribute('open'); }
measureBar();
var hv = (location.hash.match(/view=(summary|timeline|all)/) || [])[1], saved = null;
try { saved = localStorage.getItem('awr-view'); } catch (e) {}
setView(hv || (VIEWS[saved] ? saved : 'summary'), false);
addEventListener('hashchange', function(){ var v = (location.hash.match(/view=(summary|timeline|all)/) || [])[1]; if (v && v !== B.dataset.view) setView(v, false); });
var hj = (location.hash.match(/row=([\w-]+)/) || [])[1];
if (hj) goTo(document.getElementById(hj), true);
})();
