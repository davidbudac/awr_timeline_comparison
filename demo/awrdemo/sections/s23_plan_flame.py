"""Twin of sql/23_plan_flame.sql (Plan shape, old vs new).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 23_plan_flame BEGIN -->']
    out.append('<section id="plan-flame" class="vw in-s in-a lib" style="--os:13"><h2>Plan shape, old vs new'
               '<small class="h2sub">Where the time goes inside a changed plan</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_planflame.plsql'))
    out.append('<!-- AWR-SECTION: 23_plan_flame END -->')
    return "\n".join(out)
