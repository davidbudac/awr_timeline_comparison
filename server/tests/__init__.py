"""Make `server/` importable as the top-level dir for `from app import ...`
regardless of how the test run is invoked (unittest discover's inferred
top-level dir would otherwise be server/tests, not server/)."""

import sys
from pathlib import Path

_SERVER_DIR = str(Path(__file__).resolve().parents[1])
if _SERVER_DIR not in sys.path:
    sys.path.insert(0, _SERVER_DIR)
