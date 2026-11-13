# Plan 002: `server/app/views.py` has no invalid escape sequences; sort arrows render

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- server/app/views.py server/tests/test_webapp.py`
> If either file changed since this plan was written, compare the "Current
> state" excerpts against the live code before proceeding; on a mismatch,
> treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

`views.py` keeps the server UI's CSS and JavaScript in ordinary (non-raw)
Python string literals. Two things go wrong. (1) The CSS `content:" \2191"`
(an up arrow) is read by Python as the octal escape `\21` followed by `91`,
so the sort indicator on every table header is a control character plus
"91" instead of an arrow. (2) The JavaScript regexes contain `\s` and `\d`,
which are invalid Python escapes: Python 3.12 prints a `SyntaxWarning` on
import and a future Python will refuse to import the module at all. Fixing
it also unblocks a strict-warnings CI gate (plan 003).

## Current state

File: `server/app/views.py` — server-rendered HTML via `string.Template`.

`_STYLE` opens at line 20 as a plain triple-quoted string and closes at
line 137. Lines 48-49 inside it:

```python
table th.asc::after { content:" \2191"; color:var(--accent); }
table th.desc::after { content:" \2193"; color:var(--accent); }
```

`_PAGE` opens at lines 139-140 and closes at line 187:

```python
_PAGE = Template(
    """<title>$title</title>
```

Line 167 inside it (note `$$` is `string.Template`'s escape for a literal `$`):

```python
  function num(s){ var t=s.replace(/[,%\s]/g,''); return /^-?\d+(\.\d+)?$$/.test(t)?parseFloat(t):null; }
```

These three lines are the **only** backslashes inside the two literals
(verified: every other backslash in the file is a `"\n".join(...)` or
`\"` in normal code further down, outside these literals).

Current behaviour, reproducible:

```
$ python3 -W error -c "import ast; ast.parse(open('server/app/views.py').read())"
SyntaxError: invalid escape sequence '\s'
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Strict parse of one file | `python3 -W error -c "import ast; ast.parse(open('server/app/views.py').read())"` | exit 0, no output |
| Server tests | `python3 -m unittest discover -s server/tests -t .` | `OK` |
| Repo lint | `./lint.sh` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `server/app/views.py`
- `server/tests/test_webapp.py` (one new test)

**Out of scope** (do NOT touch):
- Any other change to the CSS/JS/HTML in `views.py` — this is an escaping fix only.
- Everything outside `server/`.

## Git workflow

- Branch: `advisor/002-server-views-raw-strings` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(server): raw strings for the UI's CSS/JS (sort arrows, SyntaxWarning)`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a failing test

In `server/tests/test_webapp.py`, add to class `RouteMatrixTest` (it has a
`self.dispatch("GET", "/")` helper returning a response with `.status` and
`.body` bytes — see `test_home_page` for the pattern):

```python
    def test_home_page_css_and_js_escapes_survive(self):
        r = self.dispatch("GET", "/")
        body = r.body.decode("utf-8")
        # CSS unicode escapes for the sort arrows must reach the browser intact
        self.assertIn('content:" \\2191"', body)
        self.assertIn('content:" \\2193"', body)
        # the numeric-sort regexes must keep their backslashes
        self.assertIn("/[,%\\s]/g", body)
        self.assertIn("/^-?\\d+(\\.\\d+)?$/", body)
        # no control characters leaked into the page
        self.assertNotIn("\x11", body)
```

**Verify**: `python3 -m unittest server.tests.test_webapp.RouteMatrixTest.test_home_page_css_and_js_escapes_survive -v`
→ **fails** on the first `assertIn` (expected at this step).

### Step 2: Make both literals raw strings

In `server/app/views.py`:

1. Line 20: change `_STYLE = """` to `_STYLE = r"""`.
2. Line 140: change the `"""<title>$title</title>` that opens the `_PAGE`
   template to `r"""<title>$title</title>`.

Do not change any character inside the literals. `string.Template`
substitution (`$title`, `$style`, `$body`, `$$`) is unaffected by the `r`
prefix.

**Verify**:
- `python3 -W error -c "import ast; ast.parse(open('server/app/views.py').read())"` → exit 0, no output.
- `python3 -m unittest discover -s server/tests -t .` → `OK` (one more test than before).

### Step 3: Confirm nothing else in the two literals depended on escape processing

Run:
`python3 - <<'PY'
import re
src = open('server/app/views.py').read()
for name in ('_STYLE = r"""', 'r"""<title>$title</title>'):
    i = src.index(name); j = src.index('"""', i + len(name))
    body = src[i + len(name):j]
    print(name[:12], sorted(set(re.findall(r'\\.', body))))
PY`

**Verify**: output lists exactly `['\\2']` for `_STYLE` and
`['\\.', '\\d', '\\s']` for the page template. Any other escape (for
example `\\n` or `\\t`) means a sequence that used to be processed is now
literal → STOP.

## Test plan

- New: `RouteMatrixTest.test_home_page_css_and_js_escapes_survive` in
  `server/tests/test_webapp.py` (pattern: `test_home_page` in the same class).
- Verification: `python3 -m unittest discover -s server/tests -t .` → `OK`.

## Done criteria

- [ ] `python3 -W error -c "import ast; ast.parse(open('server/app/views.py').read())"` exits 0
- [ ] `python3 -m unittest discover -s server/tests -t .` exits 0, new test included
- [ ] `./lint.sh` exits 0
- [ ] `git status --short` shows only `server/app/views.py` and `server/tests/test_webapp.py`
- [ ] `plans/README.md` status row updated

## STOP conditions

- Step 3 lists an escape other than the three named ones.
- The `_STYLE` or `_PAGE` literal no longer starts at the quoted text (file
  restructured since this plan was written).
- Any existing webapp test fails after step 2.

## Maintenance notes

- New CSS/JS added to these two literals can now use backslashes freely; a
  literal `$` in the page template still has to be written `$$`.
- Plan 003 adds a CI step that fails on any Python `SyntaxWarning`, which
  keeps this fixed.
