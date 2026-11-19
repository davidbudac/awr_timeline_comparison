"""Twin of sql/28_release_delta.sql (Before and after a release).  STUB (scaffold): the section's
owner replaces this file together with the SQL."""
from __future__ import annotations

from awrdemo import chrome


def emit(w) -> str:
    out = ['<!-- AWR-SECTION: 28_release_delta BEGIN -->']
    out.append('<section id="release-delta" class="vw in-s in-a lib" style="--os:18"><h2>Before and after a release'
               '<small class="h2sub">What moved across each marker</small></h2>')
    out.append('<p class="note">Not implemented yet.</p></section>')
    out.append(chrome.lib_script('js_reldelta.plsql'))
    out.append('<!-- AWR-SECTION: 28_release_delta END -->')
    return "\n".join(out)
