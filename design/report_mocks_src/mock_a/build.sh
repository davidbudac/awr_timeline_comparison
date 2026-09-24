#!/bin/sh
cd "$(dirname "$0")"
python3 - <<'PY'
import json
t=open('template.html').read()
d=open('data.json').read().replace('</','<\\/')
out=t.replace('__DATA__',d)
open('/Users/davidbudac/claude_projects/awr_timeline_comparison/design/report_mock_a_finding_cards.html','w').write(out)
print(len(out.encode()))
PY
