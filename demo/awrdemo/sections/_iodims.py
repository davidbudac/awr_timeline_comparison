"""
Shared engine for the two "top-N per dimension, per window" I/O trend
sections (sql/14_segment_io.sql, sql/15_file_io.sql).  Both SQL files
build the same CTE shape -- agg -> ranked -> picked -> grid -> per_x --
and walk the cursor the same way (per-dim <h3> + toggle + chart div +
collapsed detail table, per-row positional week CSVs, a JSON entry per
series, a per-dim c_json_cap accumulator).  The only differences are the
dimension codes/labels, the name/meta columns, and the CSV number
token, so those are parameters here.

Not a section: gen_demo_report.py never imports this module directly.
"""
from __future__ import annotations

from datetime import timedelta

from awrdemo import helpers as H

# PL/SQL VARCHAR2 headroom cap shared by 06/14/15 (c_json_cap).
JSON_CAP = 32500


def weeks_json(w) -> tuple[str, str]:
    """(v_weeks_json, v_weeks_iso_json): window labels oldest -> newest
    (LISTAGG ... ORDER BY week_offset DESC) as JSON string arrays."""
    labels, isos = [], []
    for k in range(w.weeks_back, -1, -1):
        t = w.target_end - timedelta(hours=w.step_hours * k)
        labels.append('"' + H.mon_dd(t) + '"')
        isos.append('"' + H.ts_min(t) + '"')
    return "[" + ",".join(labels) + "]", "[" + ",".join(isos) + "]"


def header_row(w, first_cols: str, cur_label: str) -> str:
    """'<thead>...</thead>' with the Current + one-per-prior-window
    data-w columns (REGEXP_SUBSTR('~offset_labels', ...) twin)."""
    h = "<thead><tr>" + first_cols + '<th class="num" data-w="0">' + cur_label + "</th>"
    for k in range(1, w.weeks_back + 1):
        h += '<th class="num" data-w="' + str(k) + '">&minus;' + w.offset_labels[k - 1] + "</th>"
    return h + "</tr></thead>"


def rank_pick(values_by_win: dict, dims: list, top_n: int) -> dict:
    """values_by_win[week_offset][name] = {dim_code: value} (valid windows
    only).  Returns picked[dim][(week_offset, name)] = (value, rnk) for
    ROW_NUMBER() OVER (PARTITION BY week_offset ORDER BY value DESC, name)
    <= top_n AND value > 0."""
    picked = {d: {} for d in dims}
    for off, names in values_by_win.items():
        for d in dims:
            order = sorted(names.items(), key=lambda kv: (-kv[1][d], kv[0]))
            for rnk, (name, vals) in enumerate(order, start=1):
                if rnk > top_n:
                    break
                if vals[d] > 0:
                    picked[d][(off, name)] = (vals[d], rnk)
    return picked


def per_entity(picked_dim: dict, weeks_back: int) -> list:
    """The per_seg / per_file / per_type CTE for one dim: one entry per
    distinct name with cur_val / cur_rnk / best_rank / best_value and the
    positional per-offset value + rank lists (index = week_offset, None
    = not in the top-N that window).  Sorted like the SQL ORDER BY:
    cur_rnk NULLS LAST, best_rank, best_value DESC, name."""
    names = sorted({name for (_, name) in picked_dim})
    out = []
    for name in names:
        vals = [None] * (weeks_back + 1)
        rnks = [None] * (weeks_back + 1)
        for off in range(weeks_back + 1):
            p = picked_dim.get((off, name))
            if p is not None:
                vals[off], rnks[off] = p
        present = [v for v in vals if v is not None]
        out.append({
            "name": name,
            "cur_val": vals[0],
            "cur_rnk": rnks[0],
            "best_rank": min(r for r in rnks if r is not None),
            "best_value": max(present),
            "vals": vals,
            "rnks": rnks,
        })
    out.sort(key=lambda e: (0 if e["cur_rnk"] is not None else 1,
                            e["cur_rnk"] if e["cur_rnk"] is not None else 0,
                            e["best_rank"], -e["best_value"], e["name"]))
    return out


def chart_vals(tokens: list) -> str:
    """The v_chart_vals loop: oldest -> newest, 'null' for an empty slot.
    `tokens` is the week_vals CSV split into slots (index = week_offset),
    already formatted as the SQL's TO_CHAR token or None."""
    return ",".join("null" if t is None else t for t in reversed(tokens))


def json_accumulate(acc: dict, dim: str, entry: str) -> None:
    """The v_dim_*_json / kept / total bookkeeping under c_json_cap."""
    a = acc.setdefault(dim, {"json": None, "kept": 0, "total": 0})
    a["total"] += 1
    if a["json"] is None:
        a["json"] = entry
        a["kept"] += 1
    elif len(a["json"]) + len(entry) + 1 <= JSON_CAP:
        a["json"] += "," + entry
        a["kept"] += 1


def week_cells(w, tokens: list, rnks: list, parse) -> str:
    """The FOR k IN 1 .. v_weeks_back <td> loop for one row: value parsed
    back from its CSV token (so it renders the token's precision) plus
    the '#rank' skip badge."""
    s = ""
    for k in range(1, w.weeks_back + 1):
        t = tokens[k]
        if t is None or t == "":
            s += '<td class="num" data-w="' + str(k) + '">&mdash;'
        else:
            s += '<td class="num" data-w="' + str(k) + '">' + H.fmt_num(parse(t))
        if rnks[k] is not None:
            s += ' <span class="badge skip">#' + str(rnks[k]) + "</span>"
        s += "</td>"
    return s


def new_in_cur(cur_val, tokens: list, parse) -> bool:
    """X2 'new in current': a value now, null/0 in every prior slot."""
    if cur_val is None or cur_val <= 0:
        return False
    for t in tokens[1:]:
        if t is not None and t != "" and parse(t) > 0:
            return False
    return True


def cur_cell(cur_val, cur_rnk) -> str:
    return ('<td class="num" data-w="0"' + H.fmt_num_title(cur_val) + "><b>"
            + H.fmt_num(cur_val)
            + (' <span class="badge info">#' + str(cur_rnk) + "</span>" if cur_rnk is not None else "")
            + "</b></td>")


def lift_script(entries: list, start_text: str, end_text: str) -> list:
    """Literal PUT_LINE texts from the entry whose text == start_text
    through the one == end_text (inclusive)."""
    texts = [t for t, _ in entries]
    i = texts.index(start_text)
    j = texts.index(end_text, i)
    return texts[i:j + 1]
