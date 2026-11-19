"""Twin of sql/20_load_response.sql (Load vs response time).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 20_load_response BEGIN -->']
    out.append('<section id="load-response" class="vw in-s in-a lib" style="--os:10"><h2>Load vs response time'
               '<small class="h2sub">More load, or something broken?</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_loadresp.plsql'))
    out.append('<!-- AWR-SECTION: 20_load_response END -->')
    return "\n".join(out)
