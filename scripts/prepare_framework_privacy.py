#!/usr/bin/env python3
"""Attach required-reason declarations to every locally built framework slice.
Run before Xcode embeds and signs these frameworks; never modify signed archives.
"""
from pathlib import Path
import shutil
root = Path(__file__).resolve().parents[1]
frameworks = list((root / '.build/frameworks/TailscaleKit.xcframework').glob('*/TailscaleKit.framework'))
if not frameworks:
    raise SystemExit('Missing TailscaleKit: run scripts/bootstrap_tailnet.sh first.')
for framework in frameworks:
    shutil.copyfile(root / 'Config/TailscalePrivacyInfo.xcprivacy', framework / 'PrivacyInfo.xcprivacy')
print(f'Prepared privacy declarations for {len(frameworks)} framework slices')
