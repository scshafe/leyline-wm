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
    sources=[p for p in paths if p.suffix==".md" and ("docs" in p.relative_to(REPO).parts or str(p.relative_to(REPO)).startswith(".claude/plans/") or p.name in {"README.md","CLAUDE.md"})]
    assert sources,"Maintained documentation corpus empty"
    def anchors(document: Path) -> set[str]:
        # GitHub heading slugs: lowercase, punctuation dropped, spaces become hyphens.
        return {re.sub(r"[^\w\- ]","",heading.strip().lower()).replace(" ","-")
                for heading in re.findall(r"(?m)^#{1,6}\s+(.+)$",document.read_text())}
    count=0
    for path in sources:
        for target in re.findall(r"\[[^\]]+\]\(([^\s)]+)\)",path.read_text()):
            if target.startswith(("https:","http:","mailto:")):continue
            destination,_,anchor=target.partition("#")
            document=path.parent/destination if destination else path
            assert document.exists(),f"Broken link {path.relative_to(REPO)} -> {target}"
            assert not anchor or (document.suffix==".md" and anchor in anchors(document)),f"Broken anchor {path.relative_to(REPO)} -> {target}"
            count+=1
    assert count>0,"Local document links empty"
    print(f"links: {len(sources)} documents, {count} local links")

def located(pattern: str, text: str, what: str, flags: int = 0) -> re.Match:
    match=re.search(pattern,text,flags)
    assert match,f"Cannot locate {what}"
    return match

def inventories(commands: set[str]) -> int:
    """The lists that must agree across shell, Swift and Python; drift between them is silent at runtime."""
    read=lambda rel:(REPO/rel).read_text()
    def swift_list(rel: str, name: str) -> set[str]:
        return set(re.findall(r'"([^"]+)"',located(rf"let {name}\s*=\s*\[([^\]]*)\]",read(rel),name).group(1)))
    def case_arm(rel: str) -> set[str]:
        return set(located(r"(?m)^\s*([a-z][a-z|-]*)\) ;;\s*$",read(rel),f"{rel} forwarded operations").group(1).split("|"))
    # ley: every command root is dispatched, the usage names the runtime ones, packaging ships the same set.
    ley=read("bin/ley");developer={"build","test","bench"};runtime=commands-developer
    dispatch=located(r'case "\$ley_command" in(.*?)esac',ley,"ley dispatch",re.S).group(1)
    arms={name for arm in re.findall(r"(?m)^\s*([^)*\s]+)\)",dispatch) for name in arm.split("|")}
    assert arms-commands=={"help","-h","--help","version","-v","--version","install"},f"ley dispatches unknown names: {arms-commands}"
    assert commands<=arms,f"ley does not dispatch: {commands-arms}"
    usage=located(r"cat <<'HELP'\n(.*?)\nHELP\n",ley,"ley usage",re.S).group(1)
    assert set(re.findall(r"(?m)^  ([a-z]+) ",usage))==runtime|{"install"},"ley usage drifted from the runtime commands"
    assert set(located(r"Source checkout only: ([a-z, ]+)'",ley,"ley source-only usage").group(1).split(", "))==developer,"ley source-only usage drifted"
    packaged=set(re.findall(r'"([^"]+)"',located(r"RUNTIME_COMMANDS=\{([^}]*)\}",read("scripts/release/package_release.py"),"RUNTIME_COMMANDS").group(1)))
    assert packaged==runtime,f"package_release ships {packaged}, ley runs {runtime}"
    # Shell whitelists against the Swift operation lists main.swift dispatches on.
    assert case_arm("commands/setup.sh")==swift_list("leylined/Sources/leylined/ResidentInstallation.swift","residentInstallationOperations"),"setup.sh drifted from residentInstallationOperations"
    assert case_arm("commands/resident.sh")<=swift_list("leylined/Sources/leylined/ResidentCommandClient.swift","residentClientOperations"),"resident.sh forwards an operation the client lacks"
    # Self-test suites: the shell loop runs exactly the suites main.swift knows.
    switch=located(r'case "self-test":(.*?)#endif',read("leylined/Sources/leylined/main.swift"),"self-test switch",re.S).group(1)
    swift_suites=re.findall(r'(?m)^\s*case "([^"]+)":',switch)
    shell_suites=located(r"(?m)^\s*for suite in (.+?); do",read("commands/test.sh"),"test.sh suite loop").group(1).split()
    assert len(set(swift_suites))==len(swift_suites) and set(shell_suites)==set(swift_suites),f"Self-test suites drifted: shell {sorted(set(shell_suites)^set(swift_suites))}"
    # Release version and launchd label: one spelling each.
    version=read("VERSION").strip()
    assert located(r'static let current = "([^"]+)"',read("leylined/Sources/leylined/ResidentVersion.swift"),"ResidentVersion.current").group(1)==version,"ResidentVersion.current drifted from VERSION"
    label=located(r'static let label = "([^"]+)"',read("leylined/Sources/leylined/ResidentInstallation.swift"),"ResidentInstallation.label").group(1)
    for rel,pattern in [("bin/leyline-recovery.swift",r'static let coreLabel="([^"]+)"'),("commands/doctor.sh",r"_wm_doctor_resident_launchd_fact (\S+)\)"),
                        ("tests/release/test_installation.py",r'LABEL = "([^"]+)"'),("tests/native-acceptance/measure-crash-recovery.py",r'"--label", default="([^"]+)"')]:
        assert located(pattern,read(rel),f"label in {rel}").group(1)==label,f"launchd label drifted in {rel}"
    return len(swift_suites)

def dependencies(paths: list[Path]) -> None:
    commands={"act","resident","ctl","doctor","build","test","setup","bench"}
    actual={p.stem for p in (REPO/"commands").glob("*.sh")}
    assert actual==commands,f"Unexpected command roots: {actual^commands}"
    suites=inventories(commands)
    assert {p.name for p in (REPO/"lib").iterdir()}=={"cli_output.sh"},"Retired lib root remains"
    assert {p.name for p in (REPO/"bin").glob("*-build")}=={"leylined-build","leyline-recovery-app-build"},"Retired builder remains"
    for path in (REPO/"leylined/Sources/LeylineModel").rglob("*.swift"):
        code=re.sub(r"(?m)^\s*//.*$","",path.read_text())
        assert not re.search(r"import (AppKit|ApplicationServices|CoreGraphics)",code),f"Platform import in pure model: {path}"
    for path in paths:
        if path.suffix==".swift" and "leylined/Sources" in str(path):
            code=re.sub(r"(?m)^\s*//.*$","",path.read_text())
            assert "LEYLINE_STAGE_FILE" not in code and "ModeSubscriber" not in code,f"Retired ownership transport in {path}"
    oracle=REPO/"tests/oracles"
    for rel in ["broker-rs","parcel","display_geometry","launchd","migrations"]:assert not (REPO/rel).exists(),f"Retired family remains {rel}"
    frozen=json.loads((oracle/"fixtures.sha256.json").read_text())["files"]
    assert frozen,"Frozen fixture corpus empty"
    for row in frozen:
        path=REPO/row["path"]
        assert path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==row["sha256"],f"Frozen fixture changed: {path}"
    print(f"dependencies: explicit commands/two builds, {suites} self-test suites, {len(frozen)} frozen fixture hashes")

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
