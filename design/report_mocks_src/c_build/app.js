(function(){
'use strict';
var B = document.body;
B.classList.add('js');
var $ = function(s, r){ return (r || document).querySelector(s); };
var $$ = function(s, r){ return Array.prototype.slice.call((r || document).querySelectorAll(s)); };
var WL = $$('.ruler .h').map(function(h){ return h.querySelector('.hd').textContent; });
var OFF = $$('.ruler .h').map(function(h){ return h.querySelector('.ho').textContent; });
var FULLD = $$('.ruler .h').map(function(h){ return h.title.split('.')[0]; });
var CUR = 12;

function nums(s){ return s.split(',').map(function(x){ return x === '' ? null : +x; }); }
function fmt(v){
  if (v == null) return '—';
  var a = Math.abs(v), s;
  function sig(x){ var t = Number(x.toPrecision(4)); return String(t); }
  if (a >= 1e9) return sig(v / 1e9) + 'G';
  if (a >= 1e6) return sig(v / 1e6) + 'M';
  if (a >= 1e4) return sig(v / 1e3) + 'k';
  if (a >= 1000) return Math.round(v).toLocaleString('en-US');
  return sig(v);
}
function cssNum(el, name, dflt){ var v = parseFloat(getComputedStyle(el).getPropertyValue(name)); return isNaN(v) ? dflt : v; }

/* ---- 1. mini columns for every data row ---- */
function drawBars(){
  $$('.r[data-v]').forEach(function(row){
    var vals = nums(row.dataset.v);
    var cells = $$('.c', row);
    var have = vals.filter(function(v){ return v != null; });
    var max = Math.max.apply(null, have) || 1;
    var bh = cssNum(row, '--bh', 22), bb = cssNum(row, '--bb', 6);
    var prior = vals.slice(0, CUR).filter(function(v){ return v != null; });
    cells.forEach(function(c, k){
      $$('.b,.rg', c).forEach(function(x){ x.remove(); });
      var v = vals[k]; if (v == null) return;
      var b = document.createElement('i'); b.className = 'b';
      b.style.height = Math.max(1.5, v / max * bh) + 'px';
      c.appendChild(b);
      if (k === CUR && prior.length > 1){
        var mn = Math.min.apply(null, prior), mx = Math.max.apply(null, prior);
        var rg = document.createElement('i'); rg.className = 'rg';
        rg.style.bottom = (bb + mn / max * bh) + 'px';
        rg.style.height = Math.max(2, (mx - mn) / max * bh) + 'px';
        rg.title = 'prior range ' + fmt(mn) + ' – ' + fmt(mx);
        c.appendChild(rg);
      }
    });
  });
}

/* ---- 2. ASH stacked columns ---- */
function drawAsh(){
  var row = $('#row-ash'); if (!row) return;
  var A = JSON.parse(row.dataset.ash);
  var bh = cssNum(row, '--bh', 150), bb = cssNum(row, '--bb', 8), GAP = 1.5;
  var cells = $$('.c', row);
  cells.forEach(function(c, k){
    $$('.stk,.gline,.dl', c).forEach(function(x){ x.remove(); });
    A.ticks.forEach(function(t){
      var g = document.createElement('i'); g.className = 'gline';
      g.style.bottom = (bb + t / A.max * bh) + 'px'; c.appendChild(g);
    });
    var stk = document.createElement('div'); stk.className = 'stk';
    var y = 0, segs = [];
    A.cls.forEach(function(name, i){
      var v = A.v[i][k], h = v / A.max * bh;
      if (h < 0.4) return;
      var s = document.createElement('i');
      s.style.background = A.col[i];
      s.style.bottom = y + 'px';
      s.style.height = Math.max(0.6, h - (h > 3 ? GAP : 0)) + 'px';
      segs.push({name: name, v: v, mid: y + h / 2});
      stk.appendChild(s); y += h;
    });
    c.appendChild(stk);
    if (k === CUR){
      ['User I/O', 'CPU'].forEach(function(n){
        var s = segs.filter(function(x){ return x.name === n; })[0]; if (!s) return;
        var d = document.createElement('span'); d.className = 'dl';
        d.innerHTML = n + '<b>' + s.v.toFixed(2) + '</b>';
        d.style.bottom = (bb + s.mid) + 'px';
        c.appendChild(d);
      });
    }
  });
  // y-axis ticks in the label cell
  var ax = $('.axn', row); ax.innerHTML = '';
  [0].concat(A.ticks).forEach(function(t){
    var i = document.createElement('i'); i.textContent = t;
    i.style.bottom = (bb + t / A.max * bh) + 'px'; ax.appendChild(i);
  });
}

/* ---- 3. the week before each window (Full) ---- */
function drawSpan(){
  var row = $('#row-span'); if (!row) return;
  var mx = +row.dataset.max;
  $$('svg.sa', row).forEach(function(svg){
    var a = nums(svg.dataset.a), b = nums(svg.dataset.b), n = a.length;
    var W = 100, H = 44;
    function path(vs){
      var d = 'M0,' + H;
      vs.forEach(function(v, i){ d += ' L' + (i / (n - 1) * W).toFixed(2) + ',' + (H - v / mx * H).toFixed(2); });
      return d + ' L' + W + ',' + H + 'Z';
    }
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    svg.setAttribute('preserveAspectRatio', 'none');
    var html = '<path class="ta" d="' + path(a) + '"/><path class="ua" d="' + path(b) + '"/>';
    if (svg.dataset.mk){
      svg.dataset.mk.split(';').forEach(function(m){
        var f = +m.split('|')[0];
        html += '<line class="mkt" vector-effect="non-scaling-stroke" x1="' + f * W + '" x2="' + f * W + '" y1="0" y2="' + H + '"/>';
      });
    }
    svg.innerHTML = html;
  });
}

/* ---- 4. day profile ---- */
function drawDay(){
  $$('.dr[data-v]').forEach(function(row){
    var v = nums(row.dataset.v), mu = nums(row.dataset.mu), sev = row.dataset.sev.split(',');
    var all = v.concat(mu), max = Math.max.apply(null, all) || 1, bh = 22;
    $$('.dc', row).forEach(function(c, i){
      $$('.b,.mu', c).forEach(function(x){ x.remove(); });
      var b = document.createElement('i');
      b.className = 'b' + (sev[i] === 'l' ? ' large' : sev[i] === 'm' ? ' moderate' : '');
      b.style.height = Math.max(1.5, v[i] / max * bh) + 'px'; c.appendChild(b);
      var t = document.createElement('i'); t.className = 'mu';
      t.style.bottom = (5 + mu[i] / max * bh) + 'px'; c.appendChild(t);
    });
  });
}

/* ---- 5. release / patch flags on column boundaries ---- */
var MK = window.AWR_MK || [];
function layoutFlags(){
  var fl = $('#flags'); if (!fl) return;
  fl.innerHTML = '';
  var heads = $$('.ruler .h');
  var base = fl.getBoundingClientRect().left;
  var tiers = [[], []], TH = 17;
  $$('.c.mk,.h.mk').forEach(function(c){ c.classList.remove('mk'); });
  MK.forEach(function(m){
    var x = heads[m.w].getBoundingClientRect().left - base;
    var placed = false;
    [m.l, m.s].some(function(label){
      for (var t = 0; t < tiers.length; t++){
        var f = document.createElement('div'); f.className = 'flag';
        f.textContent = label; f.style.left = x + 'px'; f.style.top = (2 + t * TH) + 'px';
        f.title = m.l + ', ' + m.t + '. Between the ' + WL[m.w - 1] + ' and ' + (m.w === CUR ? 'Current' : WL[m.w]) + ' windows';
        f.setAttribute('aria-label', f.title);
        fl.appendChild(f);
        var w = f.offsetWidth, x1 = x + w + 6;
        var clash = tiers[t].some(function(r){ return x < r[1] && x1 > r[0]; }) || x1 > fl.clientWidth + 1;
        if (!clash){
          tiers[t].push([x - 2, x1]);
          var p = document.createElement('i'); p.className = 'pole';
          p.style.left = (x - 1.5) + 'px'; p.style.top = (2 + t * TH) + 'px';
          fl.appendChild(p);
          placed = true; return true;
        }
        fl.removeChild(f);
      }
      return false;
    });
    $$('[data-w="' + m.w + '"]').forEach(function(c){ if (c.classList.contains('c') || c.classList.contains('h')) c.classList.add('mk'); });
  });
}

/* ---- 6. hover a column, pin a column, tooltip ---- */
var tip = $('#tip');
function setHW(w){ if (w == null) delete B.dataset.hw; else B.dataset.hw = w; }
function tipHTML(cell){
  var row = cell.closest('.r'); if (!row || !row.dataset.name) return '';
  var k = +cell.dataset.w, head = '<b>' + row.dataset.name + '</b><br><span class="tm">' + FULLD[k] + (k === CUR ? ', Current' : ', ' + OFF[k]) + '</span><br>';
  if (row.id === 'row-ash'){
    var A = JSON.parse(row.dataset.ash), s = '', tot = 0;
    A.cls.forEach(function(n, i){ tot += A.v[i][k]; });
    A.cls.forEach(function(n, i){ if (A.v[i][k] >= 0.05) s += '<br>' + n + ' <span class="tv">' + A.v[i][k].toFixed(2) + '</span>'; });
    return head + '<span class="tv">' + tot.toFixed(1) + '</span> active sessions' + s;
  }
  if (row.classList.contains('span')){
    return head.replace(FULLD[k], 'week ending ' + FULLD[k]) + 'grey = all classes, blue = User I/O; peak <span class="tv">' + (cell.querySelector('.v') || {}).textContent + '</span>';
  }
  var v = cell.querySelector('.v');
  if (row.classList.contains('p')) return head + '<span class="tv">' + v.textContent + '</span> <span class="tm">(' + v.dataset.raw + ')</span>';
  if (!v || v.classList.contains('nil')) return head + '<span class="tm">not in the top 10 in this window</span>';
  var extra = '';
  var g = cell.querySelector('.gl'); if (g) extra = '<br>' + g.title;
  return head + '<span class="tv">' + v.textContent + '</span> ' + (row.dataset.unit || '') + extra;
}
function placeTip(e){
  var x = e.clientX + 14, y = e.clientY + 16, w = tip.offsetWidth, h = tip.offsetHeight;
  if (x + w > innerWidth - 8) x = e.clientX - w - 12;
  if (y + h > innerHeight - 8) y = e.clientY - h - 12;
  tip.style.left = x + 'px'; tip.style.top = y + 'px';
}
var grid = $('#grid');
grid.addEventListener('mouseover', function(e){
  var c = e.target.closest('.c[data-w],.h[data-w]');
  setHW(c ? c.dataset.w : null);
  if (c && c.classList.contains('c')){
    var t = tipHTML(c);
    if (t){ tip.innerHTML = t; tip.hidden = false; placeTip(e); } else tip.hidden = true;
  } else tip.hidden = true;
});
grid.addEventListener('mousemove', function(e){ if (!tip.hidden) placeTip(e); });
grid.addEventListener('mouseleave', function(){ setHW(null); tip.hidden = true; });

var gutTitle = $('#gut-title'), gutSub = $('#gut-sub');
function ratioTxt(cur, p){
  if (cur == null || p == null || p === 0) return '—';
  var pct = (cur / p - 1) * 100, ar = pct >= 0 ? '▲ ' : '▼ ';
  if (pct >= 100) return ar + '×' + (cur / p).toFixed(1);
  return ar + (pct >= 0 ? '+' : '−') + Math.abs(pct).toFixed(1) + '%';
}
function pin(w){
  var same = B.dataset.pw === String(w);
  $$('.ruler .h').forEach(function(h){ h.setAttribute('aria-pressed', 'false'); });
  $$('.r[data-v] .g .d1').forEach(function(d){ if (d.dataset.orig != null){ d.textContent = d.dataset.orig; } });
  if (same || w == null || +w === CUR){
    delete B.dataset.pw;
    gutTitle.textContent = 'vs prior mean'; gutSub.textContent = '12 windows; click a date to pin';
    return;
  }
  B.dataset.pw = w;
  $('.ruler .h[data-w="' + w + '"]').setAttribute('aria-pressed', 'true');
  $$('.r[data-v]').forEach(function(row){
    var d = $('.g .d1', row); if (!d) return;
    var v = nums(row.dataset.v);
    if (d.dataset.orig == null) d.dataset.orig = d.textContent;
    d.textContent = ratioTxt(v[CUR], v[w]);
  });
  gutTitle.innerHTML = 'vs ' + WL[w] + ' <button type="button" id="unpin" aria-label="Clear pinned window">clear</button>';
  gutSub.textContent = 'pinned; severity still vs prior mean';
  $('#unpin').addEventListener('click', function(){ pin(null); });
}
$$('.ruler .h').forEach(function(h){ h.addEventListener('click', function(){ pin(h.dataset.w); }); });
document.addEventListener('keydown', function(e){ if (e.key === 'Escape' && B.dataset.pw) pin(null); });

/* ---- 7. scroll sync (ruler follows the grid body) ---- */
var gbody = $('#gbody'), ruler = $('#ruler');
var gin = $('#gin');
function syncCap(){ gin.style.setProperty('--sl', gbody.scrollLeft + 'px'); gin.style.setProperty('--vw', gbody.clientWidth + 'px'); }
gbody.addEventListener('scroll', function(){ ruler.scrollLeft = gbody.scrollLeft; syncCap(); }, {passive: true});
function startAtCurrent(){
  [gbody, $('#dpscroll')].forEach(function(s){ if (s && s.scrollWidth > s.clientWidth + 2) s.scrollLeft = s.scrollWidth; });
  ruler.scrollLeft = gbody.scrollLeft; syncCap();
}

/* ---- 8. lanes, modes, theme, jumps ---- */
$$('.lt').forEach(function(b){
  b.addEventListener('click', function(){
    var lane = document.getElementById(b.dataset.lane);
    var open = lane.classList.toggle('closed') === false;
    b.setAttribute('aria-expanded', String(open));
  });
});
$$('.xpb').forEach(function(b){
  b.addEventListener('click', function(){ document.getElementById(b.dataset.for).classList.add('showmore'); b.setAttribute('aria-expanded', 'true'); });
});
function setMode(full){
  B.classList.toggle('full', full); B.classList.toggle('normal', !full);
  $('#mode-full').setAttribute('aria-pressed', String(full));
  $('#mode-normal').setAttribute('aria-pressed', String(!full));
  if (full) $$('.lane.full-only').forEach(function(l){ if (l.id === 'lane-load' || l.id === 'lane-windows'){ l.classList.remove('closed'); } });
  redraw();
}
$('#mode-full').addEventListener('click', function(){ setMode(true); });
$('#mode-normal').addEventListener('click', function(){ setMode(false); });
var tf = $('#to-full'); if (tf) tf.addEventListener('click', function(){ setMode(true); });
function isDark(){ return B.classList.contains('dark') || (!B.classList.contains('light') && matchMedia('(prefers-color-scheme: dark)').matches); }
$('#theme').addEventListener('click', function(){
  var d = isDark(); B.classList.toggle('dark', !d); B.classList.toggle('light', d);
});
function reduced(){ return matchMedia('(prefers-reduced-motion: reduce)').matches; }
$$('[data-go]').forEach(function(b){
  b.addEventListener('click', function(){
    var r = document.getElementById(b.dataset.go); if (!r) return;
    var lane = r.closest('.lane'); if (lane && lane.classList.contains('closed')) $('.lt', lane).click();
    r.scrollIntoView({behavior: reduced() ? 'auto' : 'smooth', block: 'start'});
    if (gbody.scrollWidth > gbody.clientWidth + 2){ gbody.scrollLeft = gbody.scrollWidth; }
    r.classList.remove('flash'); void r.offsetWidth; r.classList.add('flash');
  });
});

function redraw(){ drawBars(); drawAsh(); drawSpan(); drawDay(); layoutFlags(); }
redraw();
startAtCurrent();
var rt; addEventListener('resize', function(){ clearTimeout(rt); rt = setTimeout(function(){ layoutFlags(); syncCap(); }, 120); });
})();
