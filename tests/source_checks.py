#!/usr/bin/env python3
"""Verify source syntax, JSON, maintained links, dependency closure and frozen bytes.

Read-only; operates on checkout files. Historical operator journals are not rewritten.
"""
from __future__ import annotations
import ast, hashlib, json, re, subprocess, sys
from pathlib import Path
REPO=Path(__file__).resolve().parents[1]

def files() -> list[Path]:
    result=subprocess.run(["git","ls-files","--cached","--others","--exclude-standard"],cwd=REPO,text=True,capture_output=True,check=True)
    return [REPO/line for line in result.stdout.splitlines() if (REPO/line).is_file()]

def syntax(paths: list[Path]) -> None:
    subprocess.run(["/bin/bash",str(REPO/"tests/shell-syntax.sh")],check=True)
    sources=[p for p in paths if p.suffix==".py"]
    assert sources,"Python source corpus empty"
    for path in sources:ast.parse(path.read_text(),filename=str(path))
    print(f"python-syntax: {len(sources)} files")

def json_data(paths: list[Path]) -> None:
    sources=[p for p in paths if p.suffix==".json"]
    assert sources,"JSON corpus empty"
    for path in sources:json.loads(path.read_bytes())
    print(f"json: {len(sources)} files")

def links(paths: list[Path]) -> None:
    sources=[p for p in paths if p.suffix==".md" and ("docs" in p.relative_to(REPO).parts or str(p.relative_to(REPO)).startswith(".claude/plans/") or p.name in {"README.md","CLAUDE.md","AX-GRANT.md"})]
    assert sources,"Maintained documentation corpus empty"
    count=0
    for path in sources:
        for target in re.findall(r"\[[^\]]+\]\(([^\s)]+)\)",path.read_text()):
            if target.startswith(("https:","http:","mailto:","#")):continue
            destination=target.split("#")[0]
            assert (path.parent/destination).exists(),f"Broken link {path.relative_to(REPO)} -> {target}"
            count+=1
    assert count>0,"Local document links empty"
    print(f"links: {len(sources)} documents, {count} local links")

def dependencies(paths: list[Path]) -> None:
    commands={"act","resident","ctl","doctor","validate","build","test","setup","bench","perf","trace"}
    actual={p.stem for p in (REPO/"commands").glob("*.sh")}
    assert actual==commands,f"Unexpected command roots: {actual^commands}"
    assert {p.name for p in (REPO/"lib").iterdir()}=={"cli_output.sh","resident_keymap.sh"},"Retired lib root remains"
    assert {p.name for p in (REPO/"bin").glob("*-build")}=={"leylined-build","leyline-recovery-app-build"},"Retired builder remains"
    for path in (REPO/"leylined/Sources/LeylineModel").rglob("*.swift"):
        code=re.sub(r"(?m)^\s*//.*$","",path.read_text())
        assert not re.search(r"import (AppKit|ApplicationServices|CoreGraphics)",code),f"Platform import in pure model: {path}"
    for path in paths:
        if path.suffix==".swift" and "leylined/Sources" in str(path):
            code=re.sub(r"(?m)^\s*//.*$","",path.read_text())
            assert "LEYLINE_STAGE_FILE" not in code and "ModeSubscriber" not in code,f"Retired ownership transport in {path}"
    oracle=REPO/"tests/oracles"
    for path in oracle.rglob("*.jq"):
        code=re.sub(r"(?m)^\s*#.*$","",path.read_text())
        for name in re.findall(r'\b(?:import|include)\s+"([\w-]+)"',code):
            assert (oracle/"jq"/(name+".jq")).exists() or (oracle/"arrange-optimizers"/(name+".jq")).exists(),f"Missing jq dependency {name} in {path}"
    for rel in ["broker-rs","parcel","display_geometry","launchd","migrations"]:assert not (REPO/rel).exists(),f"Retired family remains {rel}"
    frozen=json.loads((oracle/"fixtures.sha256.json").read_text())["files"]
    assert frozen,"Frozen fixture corpus empty"
    for row in frozen:
        path=REPO/row["path"]
        assert path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==row["sha256"],f"Frozen fixture changed: {path}"
    print(f"dependencies: explicit commands/two builds/oracle closure, {len(frozen)} original fixture hashes")

def main() -> None:
    operation=sys.argv[1] if len(sys.argv)>1 else "all";paths=files()
    operations={"syntax":syntax,"json":json_data,"links":links,"dependencies":dependencies}
    assert operation in {*operations,"all"},f"Unknown source check {operation}"
    for name,check in operations.items():
        if operation in {"all",name}:check(paths)
if __name__=="__main__":
    try:main()
    except (AssertionError,OSError,ValueError,subprocess.CalledProcessError) as error:
        print(f"not ok source-checks: {error}",file=sys.stderr);sys.exit(1)
