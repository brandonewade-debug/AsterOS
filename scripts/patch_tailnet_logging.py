#!/usr/bin/env python3
"""Honor the caller's silent logger for tsnet's user-facing auth/status logs too."""
from pathlib import Path
import sys
p = Path(sys.argv[1]) / 'tailscale.go'
s = p.read_text()
old = 'if fd == -1 {\n\t\ts.s.Logf = logger.Discard\n\t\treturn 0'
new = 'if fd == -1 {\n\t\ts.s.Logf = logger.Discard\n\t\ts.s.UserLogf = logger.Discard // AsterOS: auth URLs must not reach console logs.\n\t\treturn 0'
if new not in s:
    assert old in s, 'Pinned libtailscale logging implementation changed'
    p.write_text(s.replace(old, new, 1))
