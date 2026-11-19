"""Twin of sql/22_wait_histogram.sql (Wait latency histograms).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 22_wait_histogram BEGIN -->']
    out.append('<section id="wait-hist" class="vw in-s in-a lib" style="--os:12"><h2>Wait latency histograms'
               '<small class="h2sub">The shape of each wait the averages hide</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_waithist.plsql'))
    out.append('<!-- AWR-SECTION: 22_wait_histogram END -->')
    return "\n".join(out)
