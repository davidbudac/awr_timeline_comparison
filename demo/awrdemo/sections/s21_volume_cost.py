"""Twin of sql/21_volume_cost.sql (Volume vs unit cost).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 21_volume_cost BEGIN -->']
    out.append('<section id="volume-cost" class="vw in-s in-a lib" style="--os:11"><h2>Volume vs unit cost'
               '<small class="h2sub">Ran more often, or each run got slower?</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_volcost.plsql'))
    out.append('<!-- AWR-SECTION: 21_volume_cost END -->')
    return "\n".join(out)
