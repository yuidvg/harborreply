#!/usr/bin/env python3
"""Legacy installation helper; CLI delegates to the signed release workflow."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def install_app(source: Path, destination: Path) -> Path:
    """Copy a verified generated bundle without replacing any existing app."""
    if not destination.is_absolute() or destination.is_symlink() or not destination.is_dir():
        raise ValueError('INSTALL_DESTINATION_MUST_BE_AN_EXISTING_ABSOLUTE_DIRECTORY')
    target = destination / 'HarborReply.app'
    if target.exists() or target.is_symlink():
        raise ValueError('INSTALL_TARGET_EXISTS_CHOOSE_AN_EMPTY_DIRECTORY')
    with tempfile.TemporaryDirectory(prefix='.harborreply-install-', dir=destination) as stage:
        staged = Path(stage) / target.name
        shutil.copytree(source, staged, symlinks=True)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(staged)], check=True)
        # Reserve the target name without overwriting a concurrent installation.
        target.mkdir()
        try:
            os.rename(staged, target)
        except BaseException:
            target.rmdir()
            raise
    return target


if __name__ == '__main__':
    from release import main
    main()
