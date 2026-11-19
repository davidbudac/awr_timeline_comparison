"""Twin of sql/26_window_similarity.sql (Window similarity).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 26_window_similarity BEGIN -->']
    out.append('<section id="win-sim" class="vw in-s in-a lib" style="--os:16"><h2>Window similarity'
               '<small class="h2sub">Is the baseline itself sound, and what if a window is dropped?</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_winsim.plsql'))
    out.append('<!-- AWR-SECTION: 26_window_similarity END -->')
    return "\n".join(out)
