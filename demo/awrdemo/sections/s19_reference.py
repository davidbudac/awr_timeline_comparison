"""
Twin of sql/19_reference.sql -- the "Reading the charts" guide and the
"About this report" fold (v1.6.0), both shown in every view.  Static
markup: every literal PUT_LINE is lifted verbatim from the SQL (DEFINE
tokens substituted from the World); only the day-profile note (an
IF ~profile_days > 0 block) and the run-metadata line are ported by hand.
"""
from __future__ import annotations

from .. import chrome
from ..helpers import esc, ts_sec

SQL = chrome.sql_path("sql/19_reference.sql")


def emit(w) -> str:
    subst = {
        "target_end_resolved": ts_sec(w.target_end),
        "win_label": w.win_label,
        "step_label": w.step_label,
        "profile_days": str(w.profile_days),
        "top_n": str(w.top_n),
        "run_id": w.run_id,
        "generated_at_s": w.generated_at,
    }
    out = []
    for text, literal in chrome.put_lines(SQL):
        if not literal:
            # the run-metadata line (DBMS_XMLGEN.CONVERT('~template_name'))
            assert text.startswith('<p class="ab-meta">'), text[:60]
            text = ('<p class="ab-meta">Run <code>~run_id</code> &middot; template <code>'
                    + esc(w.template) + '</code> &middot; top_n ~top_n'
                    + ' &middot; generated ~generated_at_s &middot; read-only against '
                    + '<code>DBA_HIST_*</code>, no scratch schema.</p>')
        if text.startswith("<dt>Day profile</dt>") and w.profile_days <= 0:
            continue
        for k, v in subst.items():
            text = text.replace("~" + k, v)
        out.append(text)
    return "\n".join(out)
