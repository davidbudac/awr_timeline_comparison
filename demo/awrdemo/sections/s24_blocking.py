"""Twin of sql/24_blocking.sql (Blocking).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 24_blocking BEGIN -->']
    out.append('<section id="blocking" class="vw in-s in-a lib" style="--os:14"><h2>Blocking'
               '<small class="h2sub">Who waited on whom in the Current window</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_blocking.plsql'))
    out.append('<!-- AWR-SECTION: 24_blocking END -->')
    return "\n".join(out)
