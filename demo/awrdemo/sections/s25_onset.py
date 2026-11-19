"""Twin of sql/25_onset.sql (Onset).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 25_onset BEGIN -->']
    out.append('<section id="onset" class="vw in-s in-t in-a lib" style="--os:15"><h2>Onset'
               '<small class="h2sub">When the shift started</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_onset.plsql'))
    out.append('<!-- AWR-SECTION: 25_onset END -->')
    return "\n".join(out)
