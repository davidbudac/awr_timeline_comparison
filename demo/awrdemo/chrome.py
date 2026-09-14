"""
Lift literal DBMS_OUTPUT.PUT_LINE(...) text out of the SQL sources so the
demo report carries the SAME CSS / JS bytes the real report emits
(sql/_style.sql, sql/lib/js_*.plsql, and the literal-only stretches of
section scripts).

`put_lines(path)` returns one entry per PUT_LINE call, in order:
    (text, literal_only)
where `text` is the concatenation of every string literal in the call
(with '' unescaped) and `literal_only` is False when the call also
contained non-literal expressions (variables, CASE ..., function calls).
Non-literal parts are dropped from `text` -- callers that need them must
port that PUT_LINE by hand (they are marked so the port is easy to find).

Comment handling: `--` outside a string literal starts a line comment;
`/* */` block comments are not used by this repo's emitters.
"""
from __future__ import annotations

import os
import re

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def sql_path(rel: str) -> str:
    return os.path.join(ROOT, rel)


def _strip_comments(src: str) -> str:
    out = []
    i, n = 0, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            out.append(c)
            if c == "'":
                if i + 1 < n and src[i + 1] == "'":
                    out.append("'")
                    i += 2
                    continue
                in_str = False
            i += 1
            continue
        if c == "'":
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "-" and i + 1 < n and src[i + 1] == "-":
            j = src.find("\n", i)
            if j < 0:
                break
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


_CALL = re.compile(r"DBMS_OUTPUT\.PUT_LINE\s*\(", re.I)


def _find_call_end(src: str, start: int) -> int:
    """Return index just past the ')' closing the call opened at `start`
    (which points at the '(' )."""
    depth = 0
    i, n = start, len(src)
    in_str = False
    while i < n:
        c = src[i]
        if in_str:
            if c == "'":
                if i + 1 < n and src[i + 1] == "'":
                    i += 2
                    continue
                in_str = False
            i += 1
            continue
        if c == "'":
            in_str = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise ValueError("unbalanced PUT_LINE call")


def _eval_concat(expr: str) -> tuple[str, bool]:
    """Evaluate a `'lit' || 'lit' || expr ...` expression: literals are
    concatenated, anything else flags literal_only=False."""
    parts = []
    literal_only = True
    i, n = 0, len(expr)
    while i < n:
        c = expr[i]
        if c.isspace():
            i += 1
            continue
        if c == "'":
            j = i + 1
            buf = []
            while j < n:
                if expr[j] == "'":
                    if j + 1 < n and expr[j + 1] == "'":
                        buf.append("'")
                        j += 2
                        continue
                    break
                buf.append(expr[j])
                j += 1
            parts.append("".join(buf))
            i = j + 1
            continue
        if expr.startswith("||", i):
            i += 2
            continue
        # non-literal token: skip to the next top-level '||' (or end)
        literal_only = False
        depth = 0
        j = i
        while j < n:
            ch = expr[j]
            if ch == "'":
                # skip a nested literal inside e.g. CASE ... THEN 'x'
                k = j + 1
                while k < n:
                    if expr[k] == "'":
                        if k + 1 < n and expr[k + 1] == "'":
                            k += 2
                            continue
                        break
                    k += 1
                j = k + 1
                continue
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif depth == 0 and expr.startswith("||", j):
                break
            j += 1
        i = j
    return "".join(parts), literal_only


def put_lines(path: str) -> list[tuple[str, bool]]:
    with open(path, encoding="utf-8") as fh:
        src = _strip_comments(fh.read())
    out = []
    pos = 0
    while True:
        m = _CALL.search(src, pos)
        if not m:
            break
        open_idx = m.end() - 1
        end = _find_call_end(src, open_idx)
        inner = src[open_idx + 1:end - 1]
        out.append(_eval_concat(inner))
        pos = end
    return out


def literal_text(path: str, subst: dict | None = None) -> str:
    """Join every literal-only PUT_LINE of `path` with newlines.  Raises if
    any call was not purely literal (so a chrome file that grows a dynamic
    part is noticed rather than silently truncated).  `subst` replaces
    SQL*Plus '~name' substitution tokens in the emitted text."""
    lines = put_lines(path)
    bad = [i for i, (_, ok) in enumerate(lines) if not ok]
    if bad:
        raise ValueError(f"{path}: PUT_LINE #{bad[:5]} not literal-only")
    text = "\n".join(t for t, _ in lines)
    for k, v in (subst or {}).items():
        text = text.replace("~" + k, str(v))
    return text


def style_block() -> str:
    """The whole <style>...</style> from sql/_style.sql (SET DEFINE OFF
    there, so no substitutions)."""
    return literal_text(sql_path("sql/_style.sql"))


def lib_script(name: str) -> str:
    """One of sql/lib/js_*.plsql -> its <script>...</script> text."""
    return literal_text(sql_path(f"sql/lib/{name}"))


if __name__ == "__main__":   # quick self-check
    import sys
    p = sys.argv[1] if len(sys.argv) > 1 else sql_path("sql/_style.sql")
    for t, ok in put_lines(p):
        print(("   " if ok else "?? ") + t[:140])
