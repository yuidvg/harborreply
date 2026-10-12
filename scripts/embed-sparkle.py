#!/usr/bin/env python3
"""Embed the SwiftPM-pinned framework; sign nested code inside out."""
from pathlib import Path
import os
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
source = root/'.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
target = Path(sys.argv[1])/'Contents/Frameworks/Sparkle.framework'
target.parent.mkdir(parents=True, exist_ok=True)
if target.exists(): shutil.rmtree(target)
shutil.copytree(source, target, symlinks=True)
resources = Path(sys.argv[1])/'Contents/Resources'
resources.mkdir(parents=True, exist_ok=True)
shutil.copy2(root/'.build/artifacts/sparkle/Sparkle/LICENSE', resources/'Sparkle-LICENSE.txt')
identity = os.environ.get('HARBOR_SIGN_IDENTITY', '-')
flags = ['--force', '--sign', identity]
if identity != '-': flags += ['--options', 'runtime', '--timestamp']
for code in sorted(target.rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if code.is_symlink(): continue
    if code.suffix in ('.xpc', '.app') or code.name == 'Autoupdate':
        subprocess.run(['/usr/bin/codesign', *flags, str(code)], check=True)
subprocess.run(['/usr/bin/codesign', *flags, str(target)], check=True)
