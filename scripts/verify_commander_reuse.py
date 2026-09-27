"""Run the shipped shell template against stub executables; never install or start a real agent."""
import os
from pathlib import Path
import subprocess
import tempfile
import uuid

source = (Path(__file__).resolve().parents[1] / 'AsterOS/ServerTerminal.swift').read_text()
script = source.split('let script = #"', 1)[1].split('"#', 1)[0]
script = script.replace(r'\#(nonce)', str(uuid.uuid4()).upper())

def executable(path, body):
    path.write_text('#!/bin/sh\n' + body)
    path.chmod(0o700)

with tempfile.TemporaryDirectory(prefix='asteros-dc-test-') as temporary:
    root = Path(temporary)
    bindir = root / 'bin'; bindir.mkdir()
    appdata = root / 'appdata'; appdata.mkdir()
    log = root / 'calls'
    env = dict(os.environ, PATH=str(bindir) + ':/bin:/usr/bin', ASTER_TEST_LOG=str(log))
    executable(bindir / 'node', 'printf "node\\n" >> "$ASTER_TEST_LOG"\nprintf "Device ready\\n"\n')
    executable(bindir / 'npm', '''printf "npm\\n" >> "$ASTER_TEST_LOG"
if [ "$ASTER_TEST_FAIL" = 1 ]; then exit 1; fi
while [ "$#" -gt 0 ]; do
  if [ "$1" = --prefix ]; then destination="$2"; shift 2; else shift; fi
done
mkdir -p "$destination/node_modules/@wonderwhy-er/desktop-commander/dist"
touch "$destination/node_modules/@wonderwhy-er/desktop-commander/dist/index.js"
''')
    test_script = script.replace('/mnt/user/appdata', str(appdata))
    # Exercise the same single-quote escaping used by Swift.
    command = "bash -c '" + test_script.replace("'", "'\"'\"'") + "'"
    def run(success=True):
        result = subprocess.run(['/bin/bash', '-c', command], env=env, text=True, capture_output=True, timeout=10)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        return result.stdout
    first = run()
    assert 'Installing Desktop Commander once' in first
    marker = appdata / 'asteros/desktop-commander/.installed-0.2.51'
    assert marker.exists()
    (bindir / 'npm').rename(bindir / 'npm.saved')
    second = run()
    assert 'Reconnecting with installed Desktop Commander' in second
    assert log.read_text().splitlines() == ['npm', 'node', 'node']
    # Interrupted/failed installs must not be treated as completed.
    marker.unlink()
    (bindir / 'npm.saved').rename(bindir / 'npm')
    env['ASTER_TEST_FAIL'] = '1'
    run(success=False)
    assert not marker.exists()
    assert not (marker.parent / '.installing').exists()
    # An existing global installation also reconnects without npm.
    executable(bindir / 'desktop-commander', 'printf "existing\\n" >> "$ASTER_TEST_LOG"\n')
    before = log.read_text().splitlines().count('npm')
    assert 'Reconnecting with existing Desktop Commander' in run()
    assert log.read_text().splitlines().count('npm') == before
print('PASS: first install, download-free restart, failed-install recovery, existing installation reuse')
