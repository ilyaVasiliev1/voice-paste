#!/usr/bin/env python3
"""Source identity and local installation receipts; never reads app user data."""
import datetime
import hashlib
import json
import plistlib
import subprocess
import sys
from pathlib import Path


def source_digest(root):
    names = subprocess.check_output(
        ["git", "-C", str(root), "ls-files", "-co", "--exclude-standard", "-z"]
    ).decode().split("\0")
    digest = hashlib.sha256()
    for name in sorted(set(names)):
        if not name.startswith(("VoicePaste/", "Packages/", "scripts/", "VoicePaste.xcodeproj/")):
            continue
        path = root / name
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        if path.is_file() and not path.is_symlink():
            digest.update(name.encode() + b"\0" + path.read_bytes() + b"\0")
    return digest.hexdigest()


def stamp(app, root):
    plist = app / "Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes())
    sha = source_digest(root)
    info["VoicePasteBuildFingerprint"] = sha[:12]
    info["VoicePasteSourceDigest"] = sha
    info["VoicePasteSourceRevision"] = subprocess.check_output(
        ["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    info["VoicePasteBuildDate"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    plist.write_bytes(plistlib.dumps(info))
    return info


def receipt(app, destination):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    sha = info.get("VoicePasteSourceDigest")
    if not sha:
        raise ValueError("Build has no source identity; rebuild before installation")
    item = {"version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "source_sha256": sha, "revision": info["VoicePasteSourceRevision"],
            "built_at": info["VoicePasteBuildDate"], "path": str(app),
            "installed_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    entries = json.loads(destination.read_text()) if destination.exists() else []
    entries.append(item)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(json.dumps(entries, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(destination)
    return item


if __name__ == "__main__":
    command, *args = sys.argv[1:]
    if command == "fingerprint":
        print(source_digest(Path(args[0]))[:12])
    elif command == "stamp":
        print(stamp(Path(args[0]), Path(args[1]))["VoicePasteBuildFingerprint"])
    elif command == "receipt":
        print(json.dumps(receipt(Path(args[0]), Path(args[1])), ensure_ascii=False))
    else:
        raise SystemExit("Usage: build-info.py fingerprint ROOT | stamp APP ROOT | receipt APP JSON")
