#!/usr/bin/env python3
"""Audit public files for private metadata; never print matching private values."""
from __future__ import annotations
import argparse, getpass, json, re, subprocess
from pathlib import Path
from urllib.parse import urlparse

HOME_PATH = re.compile(rb"/(?:Users|home)/[^/\x00\s\"'<>]+", re.I)
EMAIL = re.compile(rb"[a-z0-9._%+-]+@([a-z0-9.-]+\.[a-z]{2,})", re.I)
KEY = re.compile(rb"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|\b(?:ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{60,}|AKIA[A-Z0-9]{16})")
PRIVATE_HOST = re.compile(rb"[a-z0-9.-]+\.ts\.net\b", re.I)
FORBIDDEN_PARTS = {".git", ".claude", ".build", "runtime", "__pycache__"}
FORBIDDEN_SUFFIXES = {".p12", ".pfx", ".key", ".pem", ".log", ".jsonl", ".pyc"}


def github_repository_parts(value: str) -> tuple[str, str]:
    """Validate a release destination without allowing URL/Ruby interpolation."""
    parsed=urlparse(value)
    slugs=parsed.path.strip('/').split('/')
    if (any(ord(c)<32 or ord(c)==127 for c in value) or parsed.scheme!='https'
        or parsed.netloc!='github.com' or parsed.query or parsed.fragment or len(slugs)!=2
        or not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?',slugs[0])
        or not re.fullmatch(r'[A-Za-z0-9._-]+',slugs[1]) or slugs[1] in {'.','..'}):
        raise RuntimeError('Repository must be a concrete HTTPS GitHub repository URL')
    return slugs[0],slugs[1]


def public_project_identifiers(root: Path) -> set[bytes]:
    """Permit only declared public repository URLs and their exact tap commands.

    Project ownership may be disclosed while home paths, email, private state and
    arbitrary occurrences of the same identifier remain subject to the audit.
    """
    policy_path=root/'packaging/release-policy.json'
    if not policy_path.is_file(): return set()
    policy=json.loads(policy_path.read_text())
    values=set()
    for field in ['public_repository','homebrew_repository']:
        url=policy.get(field)
        if not url: continue
        owner,repository=github_repository_parts(url)
        values.add(url.rstrip('/').encode())
        if field=='homebrew_repository':
            if not repository.startswith('homebrew-'):raise RuntimeError('Public tap must use the homebrew- repository prefix')
            values.add(f'{owner}/{repository[len("homebrew-"):]}'.encode())
    return values


def private_tokens(repository: Path) -> set[str]:
    """Infer local identities outside the exported files; findings stay redacted."""
    tokens = {getpass.getuser(), Path.home().name}
    local_identity=subprocess.run(["git","config","--get","user.name"],cwd=repository,text=True,capture_output=True).stdout.strip().lower()
    commit_identity=subprocess.run(["git","log","-1","--format=%an"],cwd=repository,text=True,capture_output=True).stdout.strip().lower()
    public_identity=local_identity=="leyline contributors" or commit_identity=="leyline contributors"
    for key in ("user.name", "user.email", "remote.origin.url"):
        result = subprocess.run(["git", "config", "--get", key], cwd=repository, text=True, capture_output=True)
        value = result.stdout.strip()
        if key.endswith("url"):
            match = re.search(r"github\.com[:/]([^/]+)/", value)
            if match and not public_identity: tokens.add(match.group(1))
        elif value: tokens.add(value)
    return {t for t in tokens if len(t) > 3 and t.lower() not in {"runner", "leyline contributors", "contributors@leyline.invalid"}}


def audit(root: Path, deny: set[str] | None = None, fresh_history: bool = False) -> list[dict[str, str]]:
    """Inspect a source/export/app tree, including literal strings in Mach-O."""
    findings: list[dict[str, str]] = []
    if fresh_history:
        def git(*args: str) -> str:
            result=subprocess.run(["git",*args],cwd=root,text=True,capture_output=True)
            if result.returncode: raise ValueError("Anonymous Git metadata could not be verified")
            return result.stdout.strip()
        expected="Leyline Contributors|contributors@leyline.invalid|Leyline Contributors|contributors@leyline.invalid"
        try:
            if (root/".git").is_symlink() or git("rev-list","--all","--count")!="1" or git("remote") or git("log","--all","--format=%an|%ae|%cn|%ce")!=expected or git("fsck","--full","--unreachable","--no-reflogs"):
                findings.append({"path":".git","code":"nonanonymous_or_extra_git_history"})
            allowed={"core.repositoryformatversion","core.filemode","core.bare","core.logallrefupdates","core.ignorecase","core.precomposeunicode","user.name","user.email"}
            keys={line.split("=",1)[0].lower() for line in git("config","--local","--list").splitlines()}
            if not keys.issubset(allowed): findings.append({"path":".git/config","code":"unexpected_git_configuration"})
        except ValueError: findings.append({"path":".git","code":"git_verification_failed"})
    token_patterns = [re.compile(rb"(?<![a-z0-9])" + re.escape(t.encode()) + rb"(?![a-z0-9])", re.I) for t in (deny or set())]
    public_identifiers=public_project_identifiers(root)
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root)
        if fresh_history and relative.parts[0]==".git": continue
        if any(part in FORBIDDEN_PARTS or part.endswith(".dSYM") for part in relative.parts):
            if path.is_dir(): findings.append({"path": str(relative), "code": "private_directory"})
            continue
        if path.is_symlink():
            try: path.resolve(strict=True).relative_to(root.resolve())
            except (OSError, ValueError): findings.append({"path": str(relative), "code": "external_or_dangling_symlink"})
            continue
        if not path.is_file(): continue
        if path.name == ".DS_Store" or path.suffix.lower() in FORBIDDEN_SUFFIXES:
            findings.append({"path": str(relative), "code": "private_artifact"}); continue
        data = path.read_bytes()
        codes = set()
        if any(pattern.search(str(relative).encode()) for pattern in token_patterns): codes.add("personal_filename")
        if HOME_PATH.search(data): codes.add("absolute_home_path")
        if KEY.search(data): codes.add("private_key_or_credential")
        if PRIVATE_HOST.search(data): codes.add("private_network_host")
        identity_data=data
        for identifier in sorted(public_identifiers,key=len,reverse=True):
            identity_data=re.sub(re.escape(identifier)+rb'(?=$|[/\s"\'<>).?#])',b'<public-project>',identity_data)
        if any(pattern.search(identity_data) for pattern in token_patterns): codes.add("personal_identifier")
        for match in EMAIL.finditer(data):
            # Frozen geometry fixtures use axis/coordinate edge-anchor tokens.
            if re.fullmatch(rb"[hv]@[0-9]+(?:\.[0-9]+)?\.(?:hi|lo)",match.group(),re.I): continue
            domain = match.group(1).decode().lower()
            if not (domain.endswith(".invalid") or domain in {"example.com", "example.org", "example.net"}): codes.add("personal_email")
        findings.extend({"path": str(relative), "code": code} for code in sorted(codes))
    return findings


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--repository", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--fresh-history",action="store_true",help="Verify and allow a single generic public Git baseline")
    parser.add_argument("--deny-file", type=Path, help="Private newline-separated identifiers; never copied into export")
    args=parser.parse_args()
    tokens=private_tokens(args.repository)
    if args.deny_file: tokens.update(t for t in args.deny_file.read_text().splitlines() if t)
    findings=audit(args.path.resolve(),tokens,args.fresh_history)
    print(json.dumps({"data":{"files_root":args.path.name,"findings":findings,"clean":not findings},"error":None,"meta":{"private_values_redacted":True}},sort_keys=True))
    return 1 if findings else 0

if __name__ == "__main__": raise SystemExit(main())
