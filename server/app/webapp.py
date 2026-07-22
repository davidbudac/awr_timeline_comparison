"""ThreadingHTTPServer + a tiny hand-rolled route table.

`dispatch()` is a pure function of (ctx, method, path, headers, body) ->
Response -- deliberately decoupled from the socket layer so tests can drive
the whole route matrix (including path-traversal attempts) without opening
a single port. `make_handler_class()` is the thin glue that turns that into
a real http.server handler.
"""

import http.server
import json
import re
import time
import urllib.parse

from . import fleetconf, paths, records, runner


class Response:
    def __init__(self, status, body=b"", content_type="text/plain; charset=utf-8", headers=None):
        self.status = status
        self.body = body if isinstance(body, bytes) else body.encode("utf-8")
        self.content_type = content_type
        self.headers = dict(headers) if headers else {}


def json_response(obj, status=200):
    return Response(status, body=json.dumps(obj, default=str).encode("utf-8"), content_type="application/json; charset=utf-8")


def html_response(html_str, status=200):
    return Response(status, body=html_str, content_type="text/html; charset=utf-8")


def text_response(text, status=200):
    return Response(status, body=text, content_type="text/plain; charset=utf-8")


def redirect(location, status=303):
    return Response(status, body=b"", headers={"Location": location})


def not_found(msg="not found"):
    return text_response(msg + "\n", status=404)


class AppContext:
    def __init__(self, config, run_manager, scheduler=None, data_dir=None, reports_dir=None):
        self.config = config
        self.run_manager = run_manager
        self.scheduler = scheduler
        self.data_dir = data_dir if data_dir is not None else paths.DATA_DIR
        self.reports_dir = reports_dir if reports_dir is not None else paths.REPORTS_DIR
        self.started_at = time.time()


def _content_type_base(content_type):
    return (content_type or "").split(";")[0].strip().lower()


def _parse_body(content_type, body_bytes):
    if not body_bytes:
        return {}
    ct = _content_type_base(content_type)
    if ct == "application/json":
        try:
            data = json.loads(body_bytes.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}
        return data if isinstance(data, dict) else {}
    try:
        parsed = urllib.parse.parse_qs(body_bytes.decode("utf-8"), keep_blank_values=True)
    except UnicodeDecodeError:
        return {}
    return {k: v[0] for k, v in parsed.items()}


# ---------------------------------------------------------------------------
# Route handlers -- signature: (ctx, match, query, content_type, body) -> Response
# ---------------------------------------------------------------------------


def h_healthz(ctx, m, query, content_type, body):
    return text_response("ok\n")


def h_home(ctx, m, query, content_type, body):
    from . import views

    error = query.get("error", [None])[0]
    return html_response(views.render_home(ctx, error=error))


def h_runs(ctx, m, query, content_type, body):
    from . import views

    return html_response(views.render_runs(ctx))


def h_run_detail(ctx, m, query, content_type, body):
    from . import views

    run_id = m.group("run_id")
    rec = records.load_record(ctx.data_dir, run_id)
    if rec is None:
        return not_found("no such run: %s" % run_id)
    return html_response(views.render_run_detail(ctx, rec))


def h_report_file(ctx, m, query, content_type, body):
    filename = m.group("filename")
    p = paths.safe_report_path(filename, reports_dir=ctx.reports_dir)
    if p is None or not p.is_file():
        return not_found("no such report")
    try:
        data = p.read_bytes()
    except OSError:
        return not_found("no such report")
    return Response(200, body=data, content_type="text/html; charset=utf-8")


def h_api_fleet_run(ctx, m, query, content_type, body):
    is_json = _content_type_base(content_type) == "application/json"
    try:
        rec = ctx.run_manager.enqueue_fleet("manual")
    except runner.ConflictError as exc:
        if is_json:
            return json_response({"error": str(exc)}, status=409)
        return redirect("/?error=" + urllib.parse.quote(str(exc)))
    if is_json:
        return json_response({"run_id": rec["run_id"], "state": rec["state"]}, status=202)
    return redirect("/runs/%s" % urllib.parse.quote(rec["run_id"]))


def h_api_detail_run(ctx, m, query, content_type, body):
    is_json = _content_type_base(content_type) == "application/json"
    data = _parse_body(content_type, body)
    alias = str(data.get("alias") or "").strip()
    if not alias or not fleetconf.ALIAS_RE.match(alias):
        msg = "missing or invalid 'alias'"
        if is_json:
            return json_response({"error": msg}, status=400)
        return redirect("/?error=" + urllib.parse.quote(msg))
    try:
        rec = ctx.run_manager.enqueue_detail(alias, "manual")
    except runner.NotFoundError as exc:
        if is_json:
            return json_response({"error": str(exc)}, status=404)
        return redirect("/?error=" + urllib.parse.quote(str(exc)))
    except runner.ConflictError as exc:
        if is_json:
            return json_response({"error": str(exc)}, status=409)
        return redirect("/?error=" + urllib.parse.quote(str(exc)))
    if is_json:
        return json_response({"run_id": rec["run_id"], "state": rec["state"]}, status=202)
    return redirect("/runs/%s" % urllib.parse.quote(rec["run_id"]))


def h_api_status(ctx, m, query, content_type, body):
    st = ctx.run_manager.status()
    sched = ctx.scheduler.status() if ctx.scheduler else {"enabled": False}
    return json_response({"run_manager": st, "scheduler": sched, "server_time": time.time()})


def h_api_runs(ctx, m, query, content_type, body):
    return json_response({"runs": records.list_records(ctx.data_dir)})


def h_api_run(ctx, m, query, content_type, body):
    run_id = m.group("run_id")
    rec = records.load_record(ctx.data_dir, run_id)
    if rec is None:
        return json_response({"error": "no such run"}, status=404)
    return json_response(rec)


def h_api_run_log(ctx, m, query, content_type, body):
    run_id = m.group("run_id")
    rec = records.load_record(ctx.data_dir, run_id)
    if rec is None:
        return json_response({"error": "no such run"}, status=404)
    offset = 0
    if "offset" in query:
        try:
            offset = max(0, int(query["offset"][0]))
        except (ValueError, IndexError):
            offset = 0
    lp = records.log_path(ctx.data_dir, run_id)
    chunk = b""
    total = 0
    if lp.exists():
        try:
            data = lp.read_bytes()
        except OSError:
            data = b""
        total = len(data)
        chunk = data[offset:]
    eof = rec.get("state") not in (records.STATE_QUEUED, records.STATE_RUNNING)
    resp = Response(200, body=chunk, content_type="text/plain; charset=utf-8")
    resp.headers["X-Log-Offset"] = str(total)
    resp.headers["X-Log-EOF"] = "1" if eof else "0"
    return resp


ROUTES = [
    ("GET", re.compile(r"^/healthz$"), h_healthz),
    ("GET", re.compile(r"^/$"), h_home),
    ("GET", re.compile(r"^/runs$"), h_runs),
    ("GET", re.compile(r"^/runs/(?P<run_id>[^/]+)$"), h_run_detail),
    ("GET", re.compile(r"^/reports/(?P<filename>[^/]+)$"), h_report_file),
    ("POST", re.compile(r"^/api/fleet/run$"), h_api_fleet_run),
    ("POST", re.compile(r"^/api/detail/run$"), h_api_detail_run),
    ("GET", re.compile(r"^/api/status$"), h_api_status),
    ("GET", re.compile(r"^/api/runs$"), h_api_runs),
    ("GET", re.compile(r"^/api/runs/(?P<run_id>[^/]+)/log$"), h_api_run_log),
    ("GET", re.compile(r"^/api/runs/(?P<run_id>[^/]+)$"), h_api_run),
]


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


def make_handler_class(ctx):
    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = "AWRFleetServer/0.1"

        def log_message(self, fmt, *args):  # noqa: A002 - stdlib signature
            pass

        def _handle(self, method):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length > 0 else b""
            resp = dispatch(ctx, method, self.path, self.headers, body)
            self.send_response(resp.status)
            self.send_header("Content-Type", resp.content_type)
            self.send_header("Content-Length", str(len(resp.body)))
            for k, v in resp.headers.items():
                self.send_header(k, v)
            self.end_headers()
            self.wfile.write(resp.body)

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

    return Handler


def create_server(ctx):
    handler_cls = make_handler_class(ctx)
    return http.server.ThreadingHTTPServer((ctx.config.bind_host, ctx.config.port), handler_cls)
