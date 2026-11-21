# Plan 034: A "Copy summary" button puts the verdict and findings on the clipboard as Markdown

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 5594f2c..HEAD -- sql/00_params.sql sql/_style.sql sql/lib/src/js_design.js sql/lib/src/css_design.css sql/lib/css_design.plsql demo/awrdemo/sections/s00_params.py demo/verify_report.js`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P3
- **Effort**: S–M
- **Risk**: LOW (client-side only, no SQL query changes)
- **Depends on**: none hard. Soft: plan 020 (adds `data-impact` /
  `data-share` on finding cards — used when present) and plan 025 (triage
  list; this plan reads the cards, not the list, so order of landing does
  not matter). Plan 022 changes the verdict's count pills; this plan does
  not read them.
- **Category**: direction (UX)
- **Planned at**: commit `5594f2c` (origin/main), re-checked 2026-11-19; first written at `ee23e49` 2026-11-17
- **Re-checked**: 2026-11-19 against `5594f2c`: valid, with one real fix.
  The top bar markup (00 lines 384-434) is unchanged; the chrome script
  and `_style.sql` moved (+12 / +7 lines; the `s00_params.py` slice +10).
  New since the first draft: the report designs. The dashboard design
  MOVES the finding cards into a findings table, so the old selector
  `#findings .cards > article.fc` finds nothing there; it is now
  `#findings article.fc:not(.chg)` (the selector `demo/verify_report.js`
  uses since the designs; `.chg` = plan / config cards, which the
  dashboard also moves into `#findings`). The dashboard adds a "Jump to"
  button before the view switch and its own Escape / Ctrl+K handlers;
  quiet / dashboard restyle the top-bar buttons, so this plan adds two
  design rules. Also: three demo pages, verify_report on classic and
  dashboard, refreshed DB-run pins and the section-pair count (29).

## Why this matters

The report is a single HTML file a DBA reads, then usually has to explain
to someone else in a ticket or a chat. Today the only copy tools are per
table (CSV / MD buttons) and per code block. Retyping the verdict and the
findings loses numbers and invites mistakes. A button in the top bar that
copies a short Markdown summary — what was compared, the verdict, the likely
source, each finding with its value and normal range, and what changed
around it — makes the report's answer portable in one click.

Target (a popover under the button; the text is also on the clipboard):

```
 [ Summary | Timeline | All sections ]  [Copy summary]  [moon]
                                        +---------------------------------------+
                                        | Copied to the clipboard.         [x]  |
                                        | +-----------------------------------+ |
                                        | |**ORCLPRD** (prd-ora-01.corp...)   | |
                                        | |Current window: Thu 10 Sep, 09:00..| |
                                        | |**Verdict:** Physical reads 5.4x...| |
                                        | |...                                | |
                                        | +-----------------------------------+ |
                                        +---------------------------------------+
```

(See also `plans/assets/ux-mockup-2026-11-17.html`, outline 15; it is a
direction, not a spec.)

## Current state

Background:

- The report is produced by SQL\*Plus scripts; `sql/00_params.sql` prints
  the page chrome (top bar, rail, chrome JavaScript) with
  `DBMS_OUTPUT.PUT_LINE('…')`. JavaScript lives **inside PL/SQL string
  literals**: a single quote must be written `''` (so use double quotes in
  JS), and a tilde must never appear (`SET DEFINE '~'` turns it into a
  substitution prompt that truncates the section).
- **Emitted text must be pure ASCII** (lint check 25). In JS, a non-ASCII
  character is written as a backslash-u escape (`✓` etc., as the file
  already does at lines 722 and 780). Agent tool input can turn a typed
  backslash-u sequence into the character itself: write such lines from a
  script and check with `grep -nP '[^\x00-\x7F]' sql/00_params.sql` (no output = good).
- `demo/awrdemo/sections/s00_params.py` is the docs-only Python twin. It
  **hand-ports the top bar** (lines 333-369) but **lifts every chrome
  `<script>` verbatim** from the SQL between the `<nav class="toc">` line and
  `<main id="main-start">` (lines 448-451, `_literal_slice`, which raises if
  a `PUT_LINE` there is not literal-only). So: new JS inside the existing
  chrome script needs no twin change, but it must be literal-only (no `~`
  substitution, no PL/SQL variables); the new button must be added to the
  twin's hand-ported top bar.

The top bar, `sql/00_params.sql:384-434` (abridged):

```sql
    DBMS_OUTPUT.PUT_LINE('<div class="topbar" id="topbar">'
        || '<div class="db"><b>' || DBMS_XMLGEN.CONVERT('~db_name') || '</b>'
        || '<span>' || DBMS_XMLGEN.CONVERT('~host_name') || ' &middot; ' ...
        || '<div class="win"><span class="cchip">Current</span><b>' ... '</b><span>vs '
        ...
        || '<span class="sp"></span>'
        || '<div class="seg" role="group" aria-label="View">' ... '</div>'
        || '<button type="button" id="theme-toggle" class="theme-icon-btn"'
        ...
        || '</button>'
        || '</div>');
```

The chrome script (`sql/00_params.sql:678` `<script>` then
`document.addEventListener("DOMContentLoaded",function(){`) already has a
clipboard helper with a fallback, lines 687-713:

```js
function paste(s){ ... hidden textarea + doc.execCommand("copy") ... }
function flash(el,done){ ... temporarily replaces el.textContent ... }
function copyText(s,el,done){
  var ok=function(){flash(el,done);};
  try{
    if(navigator.clipboard&&navigator.clipboard.writeText){
      navigator.clipboard.writeText(s).then(ok,function(){paste(s);ok();});
      return;
    }
  }catch(e){}
  paste(s); ok();
}
```

and the delegated `.copy-btn` handler at 783-791 (the pattern to follow).
Keyboard handling: a document `keydown` handler at 1225-1237 treats
`input`/`textarea` focus as typing and handles Escape (clears the window
highlight, closes the rail menu); `sql/lib/src/js_timeline.js:166` uses
Escape to clear a series highlight, then to unpin a window.

Report designs (landed after this plan was first written; `CLAUDE.md`
"### Report designs"): `design` = `classic` (default) / `quiet` /
`dashboard`. Quiet / dashboard add `sql/lib/src/css_design.css`
(→ generated `sql/lib/css_design.plsql`, `tools/js2plsql.sh css_design`)
and `sql/lib/src/js_design.js`, which runs from the page's LAST
`DOMContentLoaded` handler (after this plan's chrome code). What matters
here:

- Dashboard: `palette()` inserts `button.dsearch` ("Jump to... Ctrl K")
  into `#topbar` right BEFORE `.seg`, so the dashboard top bar reads
  `[Jump to] [Summary|Timeline|All] [Copy summary] [moon]`. It also adds
  two capture-phase `window` `keydown` listeners: Ctrl/Cmd+K opens the
  palette; Escape closes the Activity "How to read" popover ONLY while it
  is open (`stopImmediatePropagation`). Neither touches this plan's
  popover.
- Dashboard: `findTable()` MOVES every finding card into the body of a
  closed `details.drow.lead` row (in card order) and moves `#s-changes`
  (with `#changes-slot` inside it) into an `aside.dside` in `#findings`.
  So the cards are no longer `#findings .cards > article.fc`; select them
  as `#findings article.fc:not(.chg)` (`article.fc.chg` = the plan /
  config cards). `#changes-slot > article.fc` still works (the slot moves
  with its section).
- Quiet / dashboard restyle the top-bar buttons, `css_design.css` line 82:

```css
.topbar .theme-icon-btn{border-color:var(--hairline);box-shadow:0 1px 2px oklch(0 0 0 / 4%)}
```

  and the table copy menu panel (line 159, `.tmenu .tmenu-p{... background:
  var(--panel);border:1px solid var(--hairline);border-radius:10px;
  box-shadow:0 8px 24px oklch(0 0 0 / 12%)}`), which the new popover should
  match in those designs (step 3).
- `python3 demo/gen_demo_report.py` now writes three pages
  (`docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`,
  `demo_busy_db_dashboard.html`); `--check` covers all three.

What the summary reads from the DOM (all present when the button is
clicked; relocation scripts have run by then):

| Piece | Selector (verified in `docs/examples/demo_busy_db.html`) |
|---|---|
| DB name / host · version · DBID | `#topbar .db b`, `#topbar .db span` |
| Current window / "vs 12 prior windows, every 1w" | `#topbar .win b`, `#topbar .win > span:not(.cchip)` |
| Verdict sentence | `#verdict h1` (class `verdict`, `verdict quiet` when nothing moved) |
| Likely source | `#because-slot` when not `hidden` (filled by section 17) |
| One-line notes | `#narrative-slot li` when the list is not `hidden` |
| Finding cards, in order | `#findings article.fc:not(.chg)` (every design; the dashboard moves the cards into findings-table rows, in the same order) — `.fc-k .sv` (severity word), `h3`, `.fc-main .big .v`, `.big .u`, `.big .nrm`; plan 020 adds `data-impact` / `data-share` |
| Changes around it | `#changes-slot > article.fc:not([hidden])` (also in the dashboard, where `#s-changes` moves into `#findings aside.dside` with the slot inside it) — plan cards `[id^="f-plan-"]` (h3 + `.big`), the config card `#f-config` (h3 + `p.takeaway`) |
| Version / run id | `footer.report` text: "Generated by awr_trend.sql v1.6.1 — run 2026…" |

CSS for the top bar's buttons, `sql/_style.sql:1052-1057` (`.topbar
.theme-icon-btn{…border:1px solid var(--rule);border-radius:8px;background:var(--panel);…}`);
`.topbar` is `position:sticky` (line 1039), so an absolutely positioned
child is placed relative to it. `sql/_style.sql` is also included by the
fleet report's chrome: new rules must be scoped to `.topbar` / new ids so
the fleet page is unaffected.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| All DB-free checks | `./tools/check.sh` | `check.sh: all checks passed` |
| Lint | `./lint.sh` | `lint: clean (N files checked)` |
| Regenerate the design stylesheet | `tools/js2plsql.sh css_design` | `sql/lib/css_design.plsql regenerated` |
| Regenerate demo | `python3 demo/gen_demo_report.py` | three `wrote …demo_busy_db*.html` lines (classic, quiet, dashboard) |
| Demo fresh? | `python3 demo/gen_demo_report.py --check` | exit 0, three `up to date:` lines |
| Browser smoke test | `T=$(mktemp -d); (cd $T && npm i playwright@1.55 >/dev/null); NODE_PATH=$T/node_modules node demo/verify_report.js docs/examples/demo_busy_db.html`, then the same with `docs/examples/demo_busy_db_dashboard.html` | `verify: OK` for each (about 3 min each, one at a time) |
| ASCII guard | `grep -nP '[^\x00-\x7F]' sql/00_params.sql sql/_style.sql sql/lib/src/css_design.css` | no output |

No database is available to you; the DB check is in "Maintenance notes".

## Scope

**In scope**:
- `sql/00_params.sql` — the button in the top bar, the click handler inside the chrome script
- `sql/_style.sql` — rules for `#sum-btn` and `#sum-pop`
- `sql/lib/src/css_design.css`, `sql/lib/css_design.plsql` (regenerated) —
  the same two pieces in the quiet / dashboard look (step 3)
- `demo/awrdemo/sections/s00_params.py` — the button in the hand-ported top bar
- `demo/verify_report.js` — one new check
- `docs/examples/demo_busy_db.html`, `demo_busy_db_quiet.html`,
  `demo_busy_db_dashboard.html` (regenerated), `CHANGELOG.md`, `CLAUDE.md`

**Out of scope** (do NOT touch):
- `sql/lib/src/js_design.js` (the dashboard's palette / findings table):
  the summary reads the DOM it leaves behind; no change needed.
- Any section file (07, 17, 18, 12 …): the summary reads their DOM, it does not change it.
- The existing `copyText` / `paste` / `flash` helpers — reuse them, don't change them.
- The fleet report (it has its own chrome).
- URLs/links in the summary: the report is a local file; the summary is link-less.

## Git workflow

- Branch: `advisor/034-copy-summary` from `main`, which must contain
  `5594f2c` (`git merge-base --is-ancestor 5594f2c HEAD` exits 0; if not,
  STOP: the checkout predates the report designs).
- One commit: `feat(report): Copy summary button (verdict and findings as Markdown)`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: The button (hidden until the script shows it)

In `sql/00_params.sql`, in the top-bar `PUT_LINE` (384-434), insert between
the view switch's closing `'</div>'` and `'<button type="button" id="theme-toggle"'`:

```sql
        -- S1: Copy summary (plan 034); hidden until the chrome script runs,
        -- it does nothing with JavaScript off
        || '<button type="button" id="sum-btn" class="sum-btn" hidden'
        || ' aria-haspopup="dialog" aria-expanded="false"'
        || ' title="Copy the verdict and the findings as Markdown, for a ticket or a chat">Copy summary</button>'
```

In `demo/awrdemo/sections/s00_params.py`, add the identical markup at the
same place in the hand-ported top bar (between the `.seg` div's `'</div>'`
and `'<button type="button" id="theme-toggle"'`, lines 354-356).

**Verify**: `./lint.sh` → clean.

### Step 2: The click handler (inside the existing chrome script)

In `sql/00_params.sql`, inside the chrome `DOMContentLoaded` function,
right **after** the delegated `.copy-btn` handler (starts at line 783
with the comment `/* ---- C4: delegated .copy-btn (pre / code blocks) ---- */`
and ends a few lines further down with `DBMS_OUTPUT.PUT_LINE('});');`),
add these `PUT_LINE`s. They are
literal-only, use double quotes, contain no tilde and no non-ASCII
character (the bullet `*` and `-` are plain ASCII):

```sql
    DBMS_OUTPUT.PUT_LINE('/* ---- S1: Copy summary (top bar): the answer as Markdown ---- */');
    DBMS_OUTPUT.PUT_LINE('var sb=doc.getElementById("sum-btn"), sp=null;');
    DBMS_OUTPUT.PUT_LINE('function tx(el){return el?(el.textContent||"").replace(/\s+/g," ").trim():"";}');
    DBMS_OUTPUT.PUT_LINE('function sumMD(){');
    DBMS_OUTPUT.PUT_LINE('  var L=[], q=function(s,r){return (r||doc).querySelector(s);};');
    DBMS_OUTPUT.PUT_LINE('  var db=tx(q("#topbar .db b")), dx=tx(q("#topbar .db span")), wn=tx(q("#topbar .win b")), ws=tx(q("#topbar .win > span:not(.cchip)"));');
    DBMS_OUTPUT.PUT_LINE('  L.push("**"+db+"**"+(dx?" ("+dx+")":""));');
    DBMS_OUTPUT.PUT_LINE('  L.push("Current window: "+wn+(ws?", "+ws:""));');
    DBMS_OUTPUT.PUT_LINE('  L.push(""); L.push("**Verdict:** "+tx(q("#verdict h1")));');
    DBMS_OUTPUT.PUT_LINE('  var bc=q("#because-slot"); if(bc&&!bc.hidden&&tx(bc)) L.push(tx(bc));');
    DBMS_OUTPUT.PUT_LINE('  var ns=q("#narrative-slot"); if(ns&&!ns.hidden) ns.querySelectorAll("li").forEach(function(li){ if(tx(li)) L.push("- "+tx(li)); });');
    DBMS_OUTPUT.PUT_LINE('  var cs=doc.querySelectorAll("#findings article.fc:not(.chg)");');
    DBMS_OUTPUT.PUT_LINE('  if(cs.length){ L.push(""); L.push("**Findings ("+cs.length+")**"); }');
    DBMS_OUTPUT.PUT_LINE('  cs.forEach(function(c,i){');
    DBMS_OUTPUT.PUT_LINE('    var b=q(".fc-main .big",c), v=b?tx(q(".v",b))+" "+tx(q(".u",b)):"", n=b?tx(q(".nrm",b)):"";');
    DBMS_OUTPUT.PUT_LINE('    var im=c.getAttribute("data-impact"), sh=c.getAttribute("data-share");');
    DBMS_OUTPUT.PUT_LINE('    L.push((i+1)+". ["+tx(q(".fc-k .sv",c))+"] "+tx(q("h3",c))+(v.trim()?": "+v.trim():"")+(n?", "+n:"")');
    DBMS_OUTPUT.PUT_LINE('      +(im?" (+"+im+" AAS"+(sh?", "+sh+"% of the DB-time rise":"")+")":""));');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  var ch=doc.querySelectorAll("#changes-slot > article.fc:not([hidden])");');
    DBMS_OUTPUT.PUT_LINE('  if(ch.length){ L.push(""); L.push("**What changed around it**"); }');
    DBMS_OUTPUT.PUT_LINE('  ch.forEach(function(c){');
    DBMS_OUTPUT.PUT_LINE('    var b=q(".fc-main .big",c), t=q("p.takeaway",c);');
    DBMS_OUTPUT.PUT_LINE('    L.push("- "+tx(q(".fc-k .sv",c))+": "+tx(q("h3",c))+(b?": "+tx(q(".v",b))+" "+tx(q(".u",b))+", "+tx(q(".nrm",b)):"")+(t?". "+tx(t):""));');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('  var ft=tx(q("footer.report")), vm=/v(\d[0-9.]*)/.exec(ft), rm=/run (\d+)/.exec(ft);');
    DBMS_OUTPUT.PUT_LINE('  L.push(""); L.push("_From the awr_trend report"+(vm?" v"+vm[1]:"")+(rm?", run "+rm[1]:"")+"; AWR data, read-only._");');
    DBMS_OUTPUT.PUT_LINE('  return L.join("\n");');
    DBMS_OUTPUT.PUT_LINE('}');
    DBMS_OUTPUT.PUT_LINE('function sumClose(){ if(sp){ sp.hidden=true; } if(sb){ sb.setAttribute("aria-expanded","false"); } }');
    DBMS_OUTPUT.PUT_LINE('if(sb){');
    DBMS_OUTPUT.PUT_LINE('  sb.hidden=false;');
    DBMS_OUTPUT.PUT_LINE('  sb.addEventListener("click",function(ev){');
    DBMS_OUTPUT.PUT_LINE('    ev.stopPropagation();');
    DBMS_OUTPUT.PUT_LINE('    if(sp&&!sp.hidden){ sumClose(); return; }');
    DBMS_OUTPUT.PUT_LINE('    var s=sumMD();');
    DBMS_OUTPUT.PUT_LINE('    if(!sp){');
    DBMS_OUTPUT.PUT_LINE('      sp=doc.createElement("div"); sp.id="sum-pop"; sp.setAttribute("role","dialog"); sp.setAttribute("aria-label","Summary as Markdown");');
    DBMS_OUTPUT.PUT_LINE('      sp.innerHTML="<p><span class=\"sum-st\"></span><button type=\"button\" class=\"sum-x\" aria-label=\"Close\">&times;</button></p><textarea readonly rows=\"14\"></textarea>";');
    DBMS_OUTPUT.PUT_LINE('      sb.parentNode.appendChild(sp);');
    DBMS_OUTPUT.PUT_LINE('      sp.querySelector(".sum-x").addEventListener("click",sumClose);');
    DBMS_OUTPUT.PUT_LINE('      sp.addEventListener("click",function(e){ e.stopPropagation(); });');
    DBMS_OUTPUT.PUT_LINE('      sp.querySelector("textarea").addEventListener("keydown",function(e){ if(e.key==="Escape"){ e.stopPropagation(); sumClose(); sb.focus(); } });');
    DBMS_OUTPUT.PUT_LINE('      doc.addEventListener("click",function(){ if(sp&&!sp.hidden) sumClose(); });');
    DBMS_OUTPUT.PUT_LINE('    }');
    DBMS_OUTPUT.PUT_LINE('    var ta=sp.querySelector("textarea"), st=sp.querySelector(".sum-st");');
    DBMS_OUTPUT.PUT_LINE('    ta.value=s; sp.hidden=false; sb.setAttribute("aria-expanded","true");');
    DBMS_OUTPUT.PUT_LINE('    st.textContent="Copying...";');
    DBMS_OUTPUT.PUT_LINE('    var done=function(ok){ st.textContent=ok?"Copied to the clipboard.":"Select the text below and copy it."; ta.focus(); ta.select(); };');
    DBMS_OUTPUT.PUT_LINE('    try{ if(navigator.clipboard&&navigator.clipboard.writeText){ navigator.clipboard.writeText(s).then(function(){done(true);},function(){paste(s);done(false);}); return; } }catch(e){}');
    DBMS_OUTPUT.PUT_LINE('    paste(s); done(false);');
    DBMS_OUTPUT.PUT_LINE('  });');
    DBMS_OUTPUT.PUT_LINE('}');
```

Notes for the executor:
- `paste()` is the existing hidden-textarea fallback (it calls
  `execCommand("copy")`, which usually succeeds on `file://`; we still say
  "Select the text below" because we cannot detect its result reliably —
  the text is selected in the popover either way).
- `\s`, `\d` and `\n` inside the PL/SQL literal reach the browser unchanged
  (PL/SQL does not interpret backslashes).
- `\"` inside the `innerHTML` JS string is a JS escape of a double quote; in
  PL/SQL it is two plain characters. Keep it exactly as shown.
- `&times;` is an HTML entity inside `innerHTML` (ASCII in the source).
- The `#findings article.fc:not(.chg)` selector matches what
  `demo/verify_report.js:848` already uses for the cards. Do NOT use the
  old `#findings .cards > article.fc`: in the dashboard design the cards
  are no longer children of `.cards` and the summary would list none.
- This handler runs before the dashboard builds its findings table (the
  design script's `DOMContentLoaded` handler is the page's last), but the
  summary is built at CLICK time, so it always reads the final DOM.

**Verify**: `./lint.sh` → clean; `grep -nP '[^\x00-\x7F]' sql/00_params.sql`
→ no output; `awk 'length($0) > 2400' sql/00_params.sql | wc -l` → same as
`git show 5594f2c:sql/00_params.sql | awk 'length($0) > 2400' | wc -l`.

### Step 3: Styles

In `sql/_style.sql`, right after the `.topbar .theme-icon-btn` rules
(lines 1052-1057), add (one `PUT_LINE` per rule, matching the file's style;
only existing tokens: `--rule`, `--panel`, `--ink`, `--ink-soft`, `--muted`):

```sql
    -- plan 034: Copy summary (button + its popover), single-DB top bar only
    DBMS_OUTPUT.PUT_LINE('.topbar .sum-btn{flex:none;height:32px;border:1px solid var(--rule);border-radius:8px;background:var(--panel);'
        || 'font:inherit;font-size:13px;color:var(--ink-soft);padding:0 12px;cursor:pointer;white-space:nowrap}');
    DBMS_OUTPUT.PUT_LINE('.topbar .sum-btn:hover{color:var(--ink)}');
    DBMS_OUTPUT.PUT_LINE('#sum-pop{position:absolute;right:32px;top:calc(100% + 6px);width:min(560px,calc(100vw - 48px));z-index:30;'
        || 'background:var(--panel);border:1px solid var(--rule);border-radius:10px;padding:10px 12px;box-shadow:0 8px 28px rgba(0,0,0,.18)}');
    DBMS_OUTPUT.PUT_LINE('#sum-pop[hidden]{display:none}');
    DBMS_OUTPUT.PUT_LINE('#sum-pop p{display:flex;justify-content:space-between;align-items:center;margin:0 0 6px;font-size:12px;color:var(--muted)}');
    DBMS_OUTPUT.PUT_LINE('#sum-pop .sum-x{border:0;background:none;font-size:18px;line-height:1;color:var(--muted);cursor:pointer}');
    DBMS_OUTPUT.PUT_LINE('#sum-pop textarea{width:100%;box-sizing:border-box;font:12px/1.45 ui-monospace,Menlo,Consolas,monospace;'
        || 'color:var(--ink);background:var(--panel);border:1px solid var(--rule);border-radius:6px;padding:8px;resize:vertical}');
    -- at 980 px and below the top bar is position:static (line 1059), so
    -- the popover can not anchor to it: pin it to the viewport instead
    DBMS_OUTPUT.PUT_LINE('@media (max-width: 980px){#sum-pop{position:fixed;top:12px;right:12px;left:12px;width:auto}}');
```

Also hide both in print: append ` .topbar .sum-btn, #sum-pop { display:none; }`
inside the existing `@media print {` rule list (line 1589; keep the rule's
string shape).

The twin lifts `_style.sql` literally (no twin edit).

Then the quiet / dashboard look (design rules never go in `_style.sql`):
in `sql/lib/src/css_design.css`, right after line 82
(`.topbar .theme-icon-btn{border-color:var(--hairline);...}`), add:

```css
.topbar .sum-btn{border-color:var(--hairline);box-shadow:0 1px 2px oklch(0 0 0 / 4%);color:var(--muted)}
.topbar .sum-btn:hover{color:var(--ink)}
#sum-pop{border-color:var(--hairline);border-radius:10px;box-shadow:0 8px 24px oklch(0 0 0 / 12%)}
#sum-pop textarea{border-color:var(--hairline);font-family:var(--mono)}
```

and run `tools/js2plsql.sh css_design` → `sql/lib/css_design.plsql
regenerated`. (`--hairline` and `--mono` are design tokens defined at the
top of `css_design.css`, lines 12 and 33.)

**Verify**: `./lint.sh` → clean; `tools/js2plsql.sh --check` → exit 0.

### Step 4: Regenerate, check in a browser

Run `python3 demo/gen_demo_report.py` twice (the same three md5s,
`md5sum docs/examples/demo_busy_db*.html`). Then add a check to
`demo/verify_report.js`, in the phase-4 `page.evaluate` next to
`out.planOk` (~line 816; section `// ---- 6. phase 4 (v1.6.0)`, which runs
for every design). The popover reads the DOM, so the check compares its
text with the DOM it came from:

```js
      // plan 034: Copy summary builds Markdown from the verdict and the cards
      const sbtn = document.getElementById('sum-btn');
      if (sbtn && !sbtn.hidden) {
        sbtn.click(); await wait(150);
        const ta = document.querySelector('#sum-pop textarea');
        const md = ta ? ta.value : '';
        const h1 = (document.querySelector('#verdict h1') || {}).textContent || '';
        const nCards = document.querySelectorAll('#findings article.fc:not(.chg)').length;
        const nLines = (md.match(/^\d+\. \[/gm) || []).length;
        out.sumOk = md.indexOf(h1.replace(/\s+/g, ' ').trim()) >= 0 && nLines === nCards && !/undefined|null|NaN/.test(md);
        document.querySelector('#sum-pop .sum-x').click(); await wait(60);
        out.sumClosed = document.getElementById('sum-pop').hidden;
      } else out.sumOk = out.sumClosed = false;
```

(`wait` is the helper the phase-4 evaluate already defines; confirm with
`grep -n "const wait" demo/verify_report.js`. If the evaluate function is not
`async`, put this block in its own `await page.evaluate(async () => {…})`
returning `{sumOk, sumClosed}`.) Then, with the other `fail(...)` lines:

```js
    if (!p4.sumOk) fail('Copy summary: Markdown missing the verdict, a card line, or contains undefined/null');
    if (!p4.sumClosed) fail('Copy summary: the popover did not close');
```

**Verify**: browser smoke test → `verify: OK` on `demo_busy_db.html` and
then on `demo_busy_db_dashboard.html` (there the cards sit in the findings
table; `sumOk` proves the summary still lists every one). Optionally open
the demo, click "Copy summary", paste into a text editor: the verdict, 4
findings and the plan / config changes are there; Escape in the popover
closes it without unpinning anything. In the dashboard demo the button
sits between the view switch and the moon, after "Jump to"; Ctrl+K still
opens the palette, not the popover.

### Step 5: Docs

- `CHANGELOG.md` → `## Unreleased` → `### Report`: "**Copy summary.** A
  top-bar button copies the verdict, the likely source, each finding (value,
  normal range, share of the DB-time rise when known) and what changed
  around it as Markdown, and shows the text in a popover."
- `CLAUDE.md` → "Chrome hooks (v1.4.0 facelift, still live)": one bullet
  "**`#sum-btn` / `#sum-pop`** (plan 034) — Copy summary: built at click
  time from `#topbar`, `#verdict h1`, `#because-slot`, `#narrative-slot`,
  `#findings article.fc:not(.chg)` (`.fc-k .sv`, `h3`, `.big .v/.u/.nrm`,
  `data-impact` / `data-share`), `#changes-slot > article.fc` and
  `footer.report`. Renaming any of these hooks breaks the summary;
  verify_report's `sumOk` catches it. Works in every design (the
  dashboard moves the cards; the selector does not depend on `.cards`);
  quiet / dashboard style it in `css_design.css`."

**Verify**: `./tools/check.sh` → all passed. Commit.

## Test plan

- `demo/verify_report.js` new check (`sumOk`, `sumClosed`): the Markdown
  contains the verdict sentence, exactly one numbered line per finding card,
  and no `undefined`/`null`/`NaN`; the popover closes.
- Manual: light and dark theme (the popover uses tokens), and the narrow
  layout (≤ 980 px the top bar wraps; the popover must stay on screen), in
  the classic and the dashboard demo (the dashboard top bar also holds the
  "Jump to" button).

## Done criteria

- [ ] `./tools/check.sh` exits 0
- [ ] `verify_report.js` → `verify: OK` on `demo_busy_db.html` AND `demo_busy_db_dashboard.html`
- [ ] `grep -c 'id="sum-btn"' docs/examples/demo_busy_db.html docs/examples/demo_busy_db_quiet.html docs/examples/demo_busy_db_dashboard.html` → `1` for each
- [ ] `grep -nP '[^\x00-\x7F]' sql/00_params.sql sql/_style.sql sql/lib/src/css_design.css` → no output
- [ ] only in-scope files modified; `plans/README.md` row updated

## STOP conditions

Stop and report back if:

- The excerpts do not match the live code (drift).
- `python3 demo/gen_demo_report.py` raises "PUT_LINE #… not literal-only"
  (a new chrome line is not a plain literal — fix the line, do not change
  the twin's slicing).
- A selector in the table above matches nothing in the demo (a hook was
  renamed by another plan): report which one instead of guessing a new one.
- The Escape key in the popover also unpins a Timeline window or clears a
  highlight after your change (listener order differs from this plan's
  assumption).
- In the dashboard demo, `sumOk` fails because the finding cards are not
  under `#findings` any more (the design changed where it puts them).

## Maintenance notes

- **Needs owner DB run** (dbmint: `ssh -p 2200 oracle@dbmint`, never port
  2201; rsync without `--delete`). dbmint keeps only 35 days of AWR: probe
  first for a restart-free stretch (CLAUDE.md, "dbmint keeps 35 days of
  AWR"); on 2026-11-19 that was 2026-11-07 14:45 to 2026-11-09 16:15. One
  busy report (`./run_awr_trend.sh <connect> "2026-11-08 15:00" 1 8 10 0 1
  h`, a heavy blocking hour against eight quiet ones) and the same with
  `DESIGN=dashboard`: open each in Chrome from `file://`, click the
  button, paste: verdict + findings + changes present, the same lines in
  both designs. Then a quiet report (an hour of that stretch whose
  verdict reads "Nothing moved…"; probe a few): the Markdown has no
  Findings block. rc 0 and 29/29 `AWR-SECTION` pairs as usual (no SQL
  changed).
- The summary is built from the DOM, so it follows whatever the sections
  render (plans 020/022/025/027 change the cards' content; the line format
  stays). When plan 020 lands, `data-impact` / `data-share` appear on cards
  and the summary picks them up with no change here.
- The text uses the page's own characters (×, –, σ) from `textContent`;
  that is fine for a clipboard. If an ASCII-only summary is ever wanted,
  normalise in `tx()`.
