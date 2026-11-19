"""Twin of sql/27_instance_map.sql (Instance map).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 27_instance_map BEGIN -->']
    out.append('<section id="instance-map" class="vw in-s in-a lib" style="--os:17"><h2>Instance map'
               '<small class="h2sub">The findings on a picture of the instance</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_instmap.plsql'))
    out.append('<!-- AWR-SECTION: 27_instance_map END -->')
    return "\n".join(out)
