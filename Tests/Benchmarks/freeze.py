#!/usr/bin/env python3
"""Freeze exact source and locally available evidence outside the public repository."""
import hashlib
import json
import plistlib
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def freeze():
    root = Path(__file__).resolve().parents[2]
    plan = json.loads(Path(__file__).with_name("baselines.json").read_text())
    destination = Path.home() / "Library/Application Support/ToupingBenchmarks/baselines"
    destination.mkdir(parents=True, exist_ok=True)
    index_path = destination / "index.json"
    previous = json.loads(index_path.read_text()) if index_path.exists() else {}
    result = dict(schema=1, settings=plan["settings"], baselines=[])
    for baseline in plan["baselines"]:
        folder = destination / f"build{baseline['build']}"
        folder.mkdir(exist_ok=True)
        item = baseline.copy()
        item["artifacts"] = []
        if baseline["commit"]:
            commit = subprocess.check_output(["git", "rev-parse", baseline["commit"] + "^{commit}"], cwd=root, text=True).strip()
            if commit != baseline["commit"]:
                raise RuntimeError("baseline commit mismatch")
            archive = folder / "source.tar.gz"
            if not archive.exists():
                subprocess.run(["git", "archive", "--format=tar.gz", "--output", str(archive), commit], cwd=root, check=True)
            item["artifacts"].append(dict(kind="source", path=str(archive), sha256=digest(archive)))
        candidates = {21: [Path("/tmp/native21-first.log")],
                      24: [Path("/tmp/native24-wan-previous.log"), Path("/tmp/native24-wan-result.log")]}.get(baseline["build"], [])
        for source in candidates:
            target = folder / source.name
            if not target.exists() and source.exists():
                shutil.copy2(source, target)
            if target.exists():
                item["artifacts"].append(dict(kind="raw-evidence", path=str(target), sha256=digest(target)))
        if baseline["build"] == 24:
            app = folder / "MacCaster.app"
            if not app.exists():
                source = Path("/Applications/MacCaster.app")
                with (source / "Contents/Info.plist").open("rb") as stream:
                    info = plistlib.load(stream)
                if str(info["CFBundleVersion"]) != "24":
                    raise RuntimeError("refusing to label a different app version as build24")
                subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)
                shutil.copytree(source, app, symlinks=True)
            subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
            item["artifacts"].append(dict(kind="mac-executable", path=str(app), sha256=digest(app / "Contents/MacOS/MacCaster"),
                code_files={p.name: digest(p) for p in (app / "Contents/MacOS").iterdir() if p.is_file()}))
        result["baselines"].append(item)
    if previous:
        if len(previous["baselines"]) != len(result["baselines"]):
            raise RuntimeError("frozen baseline count changed")
        for old, new in zip(previous["baselines"], result["baselines"]):
            if any(new.get(k) != v for k, v in old.items() if k != "artifacts") or len(old["artifacts"]) != len(new["artifacts"]):
                raise RuntimeError("frozen baseline metadata or artifact count changed")
            for artifact, current in zip(old["artifacts"], new["artifacts"]):
                if any(current.get(key) != value for key, value in artifact.items()):
                    raise RuntimeError("existing frozen baseline differs; refusing overwrite")
    index_path.write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    print(json.dumps(dict(index=str(index_path), builds=[b["build"] for b in result["baselines"]], build21_source="unavailable")))


if __name__ == "__main__":
    freeze()
