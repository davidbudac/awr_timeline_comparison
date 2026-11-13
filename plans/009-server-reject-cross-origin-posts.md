# Plan 009: The fleet server refuses state-changing requests that come from another web origin

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat e755b97..HEAD -- server/app/webapp.py server/tests/test_webapp.py server/README.md`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (touches `server/tests/test_webapp.py`, also edited by plan 002 — rebase if it landed)
- **Category**: security
- **Planned at**: commit `e755b97`, 2026-11-13

## Why this matters

The AWR Fleet Server has no login by design; it relies on being bound to
`127.0.0.1` (or sitting behind an authenticating proxy). That protects it
from other machines, but not from the operator's own browser: any web page
the operator visits can submit a form to `http://127.0.0.1:8765/api/fleet/run`
and the browser will deliver it. The two POST routes start real work — a
fleet run opens sessions on every database in `fleet.conf` and can run for
an hour. Nothing in the server checks where a POST came from. This plan adds
the standard same-origin check for POST requests (a request-authenticity
check), which the server's own pages pass automatically.

## Current state

File `server/app/webapp.py` — a hand-rolled route table over `http.server`.
`dispatch()` is a pure function used by both the real handler and the tests
(`:225-247`):

```python
def dispatch(ctx, method, raw_path, headers, body):
    """headers: a mapping supporting .get(name) case-insensitively (an
    http.client.HTTPMessage works; a plain dict with a 'Content-Type' key
    works fine too for tests)."""
    parsed = urllib.parse.urlsplit(raw_path)
    path = urllib.parse.unquote(parsed.path)
    query = urllib.parse.parse_qs(parsed.query)
    content_type = headers.get("Content-Type") if headers else None

    matched_path = False
    for rt_method, regex, handler in ROUTES:
        m = regex.match(path)
        if not m:
            continue
        matched_path = True
        if rt_method == method:
            try:
                return handler(ctx, m, query, content_type, body)
            except Exception as exc:  # pragma: no cover -- last-resort safety net
                return json_response({"error": "internal server error: %s" % exc}, status=500)
    if matched_path:
        return text_response("method not allowed\n", status=405)
    return not_found("no such route: %s %s" % (method, path))
```

The only POST routes (`:216-217`):

```python
    ("POST", re.compile(r"^/api/fleet/run$"), h_api_fleet_run),
    ("POST", re.compile(r"^/api/detail/run$"), h_api_detail_run),
```

There is no reference to `Origin`, `Referer` or `Host` anywhere in
`server/app/*.py`.

Helpers available in the same file: `text_response(text, status=200)`,
`json_response(obj, status=200)`, `_content_type_base(content_type)`.

Tests: `server/tests/test_webapp.py` has `WebappTestBase` with

```python
    def dispatch(self, method, path, headers=None, body=b""):
        return webapp.dispatch(self.ctx, method, path, headers or {}, body)
```

and class `PostEndpointsTest(WebappTestBase)` whose tests POST with
`headers={"Content-Type": "application/json"}` (no `Origin`) — the shape a
`curl` / script client sends. Those must keep working. Test header dicts
are plain `dict`s, so header names are looked up with the exact spelling
used below (`"Origin"`, `"Referer"`, `"Host"`, `"X-Forwarded-Host"`); the
real `http.client.HTTPMessage` is case-insensitive.

`server/README.md` has a "## Data & security" section whose bullet starts
"- **No authentication.** Default bind is `127.0.0.1`. …".

How browsers behave (the basis of the check):

- A browser attaches an `Origin` header to every cross-origin POST, and to
  same-origin POSTs as well; a page that hides its origin sends
  `Origin: null`. A page on another site cannot forge or remove it.
- Non-browser clients (`curl`, scripts, the server's own tests) usually send
  neither `Origin` nor `Referer`. They are not driven by a hostile web page,
  so they are allowed.
- Behind a reverse proxy the `Host` header may be rewritten while the
  browser's `Origin` still names the public host; proxies then pass the
  original host in `X-Forwarded-Host`. A cross-site page cannot set that
  header on a plain form post, so accepting it does not weaken the check.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Server tests | `python3 -m unittest discover -s server/tests -t .` | `OK` |
| One class | `python3 -m unittest server.tests.test_webapp.PostOriginCheckTest -v` | all pass |
| Lint | `./lint.sh` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `server/app/webapp.py`
- `server/tests/test_webapp.py`
- `server/README.md` (one bullet)

**Out of scope** (do NOT touch):
- Adding authentication, sessions, tokens or cookies — the no-auth posture
  is a documented design decision.
- GET routes. They stay unrestricted (they change nothing).
- Everything outside `server/`.

## Git workflow

- Branch: `advisor/009-server-reject-cross-origin-posts` from `main`.
- Commit style: conventional commits with scope. Suggested:
  `fix(server): refuse cross-origin POSTs (same-origin check)`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Write the failing tests

Add to `server/tests/test_webapp.py`, after `PostEndpointsTest`:

```python
class PostOriginCheckTest(WebappTestBase):
    """State-changing routes must refuse requests issued by another web
    origin, and keep working for the server's own pages and for scripts."""

    JSON = {"Content-Type": "application/json"}

    def _post(self, extra):
        headers = dict(self.JSON)
        headers.update(extra)
        return self.dispatch("POST", "/api/fleet/run", headers=headers, body=b"{}")

    def test_no_origin_no_referer_is_allowed(self):
        self.assertEqual(self._post({}).status, 202)

    def test_same_origin_is_allowed(self):
        r = self._post({"Host": "127.0.0.1:8765", "Origin": "http://127.0.0.1:8765"})
        self.assertEqual(r.status, 202)

    def test_same_origin_via_referer_is_allowed(self):
        r = self._post({"Host": "127.0.0.1:8765", "Referer": "http://127.0.0.1:8765/"})
        self.assertEqual(r.status, 202)

    def test_cross_origin_is_refused(self):
        r = self._post({"Host": "127.0.0.1:8765", "Origin": "https://example.org"})
        self.assertEqual(r.status, 403)
        self.assertEqual(self.rm.enqueue_fleet_calls, [])

    def test_cross_origin_referer_is_refused(self):
        r = self._post({"Host": "127.0.0.1:8765", "Referer": "https://example.org/page"})
        self.assertEqual(r.status, 403)

    def test_null_origin_is_refused(self):
        r = self._post({"Host": "127.0.0.1:8765", "Origin": "null"})
        self.assertEqual(r.status, 403)

    def test_different_port_is_refused(self):
        r = self._post({"Host": "127.0.0.1:8765", "Origin": "http://127.0.0.1:3000"})
        self.assertEqual(r.status, 403)

    def test_host_comparison_is_case_insensitive(self):
        r = self._post({"Host": "Fleet.Example.Net", "Origin": "https://fleet.example.net"})
        self.assertEqual(r.status, 202)

    def test_proxy_forwarded_host_is_accepted(self):
        r = self._post(
            {
                "Host": "127.0.0.1:8765",
                "X-Forwarded-Host": "fleet.example.net",
                "Origin": "https://fleet.example.net",
            }
        )
        self.assertEqual(r.status, 202)

    def test_detail_route_is_guarded_too(self):
        r = self.dispatch(
            "POST",
            "/api/detail/run",
            headers={"Content-Type": "application/json", "Host": "127.0.0.1:8765", "Origin": "https://example.org"},
            body=b'{"alias": "good1"}',
        )
        self.assertEqual(r.status, 403)

    def test_get_is_never_blocked(self):
        r = self.dispatch("GET", "/healthz", headers={"Host": "127.0.0.1:8765", "Origin": "https://example.org"})
        self.assertEqual(r.status, 200)
```

`self.rm` is the `FakeRunManager` defined at the top of the test file; it
records every `enqueue_fleet(trigger)` call in the list
`enqueue_fleet_calls`, so an empty list proves the refused request never
reached the run manager. Do not modify `FakeRunManager`.

**Verify**: `python3 -m unittest server.tests.test_webapp.PostOriginCheckTest -v`
→ the `…_refused` tests **fail** (they get 202), the `…_allowed` tests pass.
That is the expected state after this step.

### Step 2: Implement the check

In `server/app/webapp.py`, add above `dispatch()`:

```python
def _same_origin(headers):
    """Request-authenticity check for state-changing (POST) routes.

    A browser attaches Origin (or at least Referer) to a cross-site POST and
    a page on another site cannot forge either, so a POST is accepted when:
      - it carries neither header (curl / scripts -- not driven by a web
        page), or
      - the header's host[:port] equals the Host the request was sent to
        (or X-Forwarded-Host, when a reverse proxy rewrote Host).
    'Origin: null' (an opaque origin) is refused. This is not
    authentication -- see server/README.md, "Data & security".
    """
    if not headers:
        return True
    source = headers.get("Origin")
    if source is None:
        source = headers.get("Referer")
    if source is None:
        return True
    source = source.strip()
    if not source or source.lower() == "null":
        return False
    try:
        netloc = urllib.parse.urlsplit(source).netloc.lower()
    except ValueError:
        return False
    if not netloc:
        return False
    allowed = set()
    for name in ("Host", "X-Forwarded-Host"):
        value = headers.get(name)
        if value:
            for part in value.split(","):
                part = part.strip().lower()
                if part:
                    allowed.add(part)
    return netloc in allowed
```

In `dispatch()`, inside the loop, guard the handler call:

```python
        if rt_method == method:
            if method == "POST" and not _same_origin(headers):
                return text_response("cross-origin request refused\n", status=403)
            try:
                return handler(ctx, m, query, content_type, body)
```

Nothing else in `dispatch()` changes.

**Verify**:
- `python3 -m unittest server.tests.test_webapp -v` → all pass, including
  every pre-existing `PostEndpointsTest` test.
- `python3 -m unittest discover -s server/tests -t .` → `OK`.

### Step 3: Document it

In `server/README.md`, section "## Data & security", add a bullet directly
after the "**No authentication.**" bullet:

```markdown
- **Cross-site requests are refused.** The two state-changing routes
  (`POST /api/fleet/run`, `POST /api/detail/run`) reject a request whose
  `Origin` / `Referer` names a different host than the one it was sent to
  (HTTP 403), so a web page open in your browser cannot start runs. This is
  not authentication: scripts that send neither header are accepted, and
  anyone who can reach the port can still use the server. Behind a reverse
  proxy that rewrites `Host`, have it pass `X-Forwarded-Host`.
```

**Verify**: `grep -c "Cross-site requests are refused" server/README.md` → `1`.

### Step 4: Manual smoke test against the real handler (optional but quick)

Only if port 8765 is free and you may start a local process: skip this step
otherwise — the `dispatch()` tests cover the logic, and the real handler
passes `self.headers` straight to `dispatch()`.

## Test plan

- New class `PostOriginCheckTest` (11 tests) in `server/tests/test_webapp.py`:
  no-header client, same origin via `Origin`, via `Referer`, cross origin,
  cross-origin referer, `null`, different port, case-insensitivity, proxy
  `X-Forwarded-Host`, the detail route, GET unaffected.
- All pre-existing tests unchanged and passing.
- Verification: `python3 -m unittest discover -s server/tests -t .` → `OK`.

## Done criteria

- [ ] `python3 -m unittest discover -s server/tests -t .` exits 0, `PostOriginCheckTest` included
- [ ] `grep -c "_same_origin" server/app/webapp.py` ≥ 2
- [ ] `./lint.sh` exits 0
- [ ] `git status --short` shows only the three in-scope files
- [ ] `plans/README.md` status row updated

## STOP conditions

- A pre-existing POST test fails after step 2 (the check is rejecting a
  legitimate client shape) — report which headers it sent.
- `dispatch()` no longer has the loop shape shown in "Current state".
- You find the server's own HTML forms post to a different origin than the
  page (they should not — `grep -n "action=" server/app/views.py` must show
  only relative URLs such as `/api/fleet/run`); if any is absolute, report.

## Maintenance notes

- Any new state-changing route must be a POST so it inherits the check; do
  not add GET routes with side effects.
- Reviewer: check that requests with neither `Origin` nor `Referer` are
  still accepted (CLI use) and that the comparison includes the port.
