#!/usr/bin/env python3
"""Build anonymous Leyline source/app archives and a checksum-bound install recipe.

Does not publish or install anything. Requires a selected LICENSE. Builds in a
neutral temporary source tree, excludes private history/state and scans artifacts.
"""
from __future__ import annotations
import argparse, gzip, hashlib, json, os, plistlib, shutil, stat, subprocess, sys, tarfile, tempfile
from pathlib import Path
from privacy_audit import FORBIDDEN_PARTS, FORBIDDEN_SUFFIXES, audit, private_tokens, github_repository_parts

ROOT=Path(__file__).resolve().parents[2]
SOURCE_ROOTS={"bin","commands","docs","keymap","leylined","lib","packaging","scripts","tests",".github"}
SOURCE_FILES={"README.md","CLAUDE.md","LICENSE","VERSION",".gitignore","install.sh"}
RUNTIME_COMMANDS={"act","resident","ctl","doctor","setup"}


def run(args: list[str], cwd: Path | None = None, env: dict[str,str] | None = None) -> str:
    result=subprocess.run(args,cwd=cwd,text=True,capture_output=True,env=env)
    if result.returncode: raise RuntimeError(f"Release operation failed: {args[0]}\n{result.stdout[-4000:]}\n{result.stderr[-4000:]}")
    return result.stdout.strip()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def app_shell(template: Path, app: Path, version: str) -> Path:
    """The bundle's MacOS directory plus its Info.plist stamped with the release version."""
    (app/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
    plist=plistlib.loads(template.read_bytes())
    plist['CFBundleShortVersionString']=plist['CFBundleVersion']=version
    (app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
    return app


def source_files(repository: Path) -> list[Path]:
    """Tracked files only: untracked work never enters a public export."""
    result=run(["git","ls-files","--cached"],cwd=repository)
    paths=[]
    for line in result.splitlines():
        relative=Path(line)
        if not relative.parts or (relative.parts[0] not in SOURCE_ROOTS and line not in SOURCE_FILES): continue
        if any(p in FORBIDDEN_PARTS or p.endswith(".dSYM") for p in relative.parts): continue
        path=repository/relative
        if not path.exists(): continue
        if path.is_symlink(): raise RuntimeError(f"Source export does not accept symlinks: {relative}")
        if path.is_file():
            if path.name==".DS_Store" or path.suffix in FORBIDDEN_SUFFIXES: continue
            if path.read_bytes()[:4] in {b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'}: continue
            paths.append(relative)
    return sorted(set(paths))


def export_source(repository: Path, destination: Path, deny: set[str]) -> None:
    if destination.exists(): raise RuntimeError('Source export destination already exists')
    destination.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.leyline-export-',dir=destination.parent) as directory:
        staged=Path(directory)/destination.name;staged.mkdir()
        for relative in source_files(repository):
            target=staged/relative;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(repository/relative,target)
            target.chmod(0o755 if (repository/relative).stat().st_mode & stat.S_IXUSR else 0o644)
        findings=audit(staged,deny)
        if findings: raise RuntimeError('Source privacy audit failed: '+json.dumps(findings))
        os.replace(staged,destination)


def archive_source(source: Path, output: Path) -> None:
    """Stable names/modes/mtime; no private Git directory or platform sidecars."""
    with output.open('wb') as raw, gzip.GzipFile(filename='',mode='wb',fileobj=raw,mtime=0) as compressed:
        with tarfile.open(fileobj=compressed,mode='w',format=tarfile.PAX_FORMAT) as archive:
            for path in [source,*sorted(source.rglob('*'))]:
                if '.git' in path.relative_to(source.parent).parts: continue
                info=archive.gettarinfo(str(path),arcname=str(path.relative_to(source.parent)))
                info.uid=info.gid=0;info.uname=info.gname='';info.mtime=0;info.pax_headers={}
                if path.is_file():
                    with path.open('rb') as content:archive.addfile(info,content)
                else:archive.addfile(info)


def anonymous_history(source: Path, version: str) -> None:
    """Create a fresh public baseline, never copy/rewrite the private history."""
    run(['git','-c','init.defaultBranch=main','init'],cwd=source)
    run(['git','config','user.name','Leyline Contributors'],cwd=source)
    run(['git','config','user.email','contributors@leyline.invalid'],cwd=source)
    run(['git','add','.'],cwd=source)
    env={**os.environ,'GIT_AUTHOR_NAME':'Leyline Contributors','GIT_COMMITTER_NAME':'Leyline Contributors',
         'GIT_AUTHOR_EMAIL':'contributors@leyline.invalid','GIT_COMMITTER_EMAIL':'contributors@leyline.invalid',
         'GIT_AUTHOR_DATE':'2000-01-01T00:00:00+0000','GIT_COMMITTER_DATE':'2000-01-01T00:00:00+0000'}
    run(['git','-c','core.hooksPath=/dev/null','-c','commit.gpgsign=false','commit','-m',f'Leyline {version} public baseline'],cwd=source,env=env)
    run(['git','tag',f'v{version}'],cwd=source)
    assert run(['git','rev-list','--count','HEAD'],cwd=source)=='1'
    assert not run(['git','remote'],cwd=source)


def app_resources(source: Path, app: Path, version: str) -> Path:
    home=app/'Contents/Resources/leyline';home.mkdir(parents=True)
    for name in ['keymap','lib']:
        shutil.copytree(source/name,home/name)
    (home/'commands').mkdir();(home/'bin').mkdir()
    for name in RUNTIME_COMMANDS:shutil.copy2(source/f'commands/{name}.sh',home/f'commands/{name}.sh')
    shutil.copy2(source/'bin/ley',home/'bin/ley')
    (home/'bin/leylined').symlink_to('../../../MacOS/leylined')
    shutil.copy2(source/'VERSION',home/'VERSION');shutil.copy2(source/'LICENSE',home/'LICENSE')
    (home/'release.json').write_text(json.dumps({'version':version,'profile':'application'},sort_keys=True)+'\n')
    return home


def build_application(source: Path, output: Path, architecture: str, identity: str | None, notary: str | None) -> Path:
    env={**os.environ,'LEYLINE_CODESIGN_IDENTITY':identity or '-'}
    if identity:env['LEYLINE_DISTRIBUTION_SIGNING']='1'
    else:env.pop('LEYLINE_DISTRIBUTION_SIGNING',None)
    version=(source/'VERSION').read_text().strip()
    app=app_shell(source/'packaging/Leyline.Info.plist',output/'Leyline.app',version)
    app_resources(source,app,version)
    arches=['arm64','x86_64'] if architecture=='universal' else [architecture]
    products=[];recovery_products=[]
    for arch in arches:
        binary=output/f'leylined-{arch}'
        run([str(source/'bin/leylined-build'),'--output',str(binary),'--arch',arch,'--scratch-path',str(output/f'build-{arch}')],cwd=source,env=env)
        products.append(binary)
        recovery=output/f'Recovery-{arch}.app'
        run([str(source/'bin/leyline-recovery-app-build'),'--output-app',str(recovery),'--arch',arch],cwd=source,env=env)
        recovery_products.append(recovery/'Contents/MacOS/leyline-recovery')
    recovery=app_shell(source/'bin/leyline-recovery.Info.plist',output/'Leyline Recovery.app',version)
    for paths,target in [(products,app/'Contents/MacOS/leylined'),(recovery_products,recovery/'Contents/MacOS/leyline-recovery')]:
        if len(paths)==1:shutil.copy2(paths[0],target)
        else:run(['/usr/bin/lipo','-create',*[str(p) for p in paths],'-output',str(target)])
    for bundle,identifier in [(app,'org.leyline'),(recovery,'org.leyline.recovery')]:
        run([str(source/'bin/leyline-codesign'),str(bundle),identifier],env=env)
        run(['/usr/bin/codesign','--verify','--strict','--deep',str(bundle)])
    if notary:
        if not identity:raise RuntimeError('Notarization requires deliberate Developer ID signing')
        submission=output/'notary-submission.zip'
        run(['/usr/bin/ditto','-c','-k','--keepParent',str(app),str(submission)])
        run(['/usr/bin/xcrun','notarytool','submit',str(submission),'--keychain-profile',notary,'--wait'])
        run(['/usr/bin/xcrun','stapler','staple',str(app)])
        # Recovery is independent and must have its own ticket.
        run(['/usr/bin/ditto','-c','-k','--keepParent',str(recovery),str(submission)])
        run(['/usr/bin/xcrun','notarytool','submit',str(submission),'--keychain-profile',notary,'--wait'])
        run(['/usr/bin/xcrun','stapler','staple',str(recovery)])
    return app


def assemble_existing(source: Path, output: Path) -> None:
    """Assemble locally built shipping binaries; no developer runtime is accepted."""
    binary=source/'bin/leylined';version=(source/'VERSION').read_text().strip()
    if run([str(binary),'version']).split()[-1]!=version:raise RuntimeError('Built version differs from VERSION')
    probe=subprocess.run([str(binary),'self-test','model'],capture_output=True)
    if probe.returncode!=64:raise RuntimeError('Shipping binary exposes developer test commands')
    app=app_shell(source/'packaging/Leyline.Info.plist',output/'Leyline.app',version)
    shutil.copy2(binary,app/'Contents/MacOS/leylined')
    app_resources(source,app,version)
    shutil.copytree(source/'bin/Leyline Recovery.app',output/'Leyline Recovery.app')
    run([str(source/'bin/leyline-codesign'),str(app),'org.leyline'])
    run(['/usr/bin/codesign','--verify','--strict','--deep',str(app)])


def install_recipe(repository_url: str, version: str, source_archive: Path, output: Path) -> Path:
    github_repository_parts(repository_url)
    url=repository_url.rstrip('/')+f'/releases/download/v{version}/{source_archive.name}'
    recipe=output/'leyline.rb'
    recipe.write_text(f'''class Leyline < Formula
  desc "Native macOS window manager with per-Space controls"
  homepage "{repository_url}"
  url "{url}"
  sha256 "{digest(source_archive)}"
  version "{version}"
  license "MIT"
  depends_on macos: :sonoma
  depends_on "jq"

  def install
    # Homebrew already sandboxes the build; SwiftPM cannot nest sandbox-exec.
    system "bin/leylined-build", "--disable-sandbox"
    system "bin/leyline-recovery-app-build"
    system "/usr/bin/python3", "scripts/release/package_release.py", "--assemble-only", "--output", "assembled"
    libexec.install "assembled/Leyline.app", "assembled/Leyline Recovery.app", "install.sh"
    bin.write_exec_script libexec/"Leyline.app/Contents/Resources/leyline/bin/ley"
  end

  def caveats
    <<~EOS
      Run: ley install --start
      This copies both apps to ~/Applications and registers the per-user service.
      Allow Accessibility and Input Monitoring when requested.
      Local builds are ad-hoc signed; updates may require renewed permissions.
      Source builds require Swift 6 or newer from Xcode Command Line Tools.
    EOS
  end

  test do
    assert_match "{version}", shell_output("#{{bin}}/ley --version")
  end
end
''')
    return recipe


def main() -> int:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'dist')
    parser.add_argument('--arch',choices=['universal','arm64','x86_64'],default='universal')
    parser.add_argument('--source-only',action='store_true')
    parser.add_argument('--anonymous-history',action='store_true')
    parser.add_argument('--repository',help='Neutral public GitHub HTTPS repository; generates a bound Homebrew recipe')
    parser.add_argument('--sign-identity',help='Optional deliberate Developer ID publisher identity (visible in signature)')
    parser.add_argument('--notary-profile',help='Existing keychain profile; never accepts credentials on command line')
    parser.add_argument('--assemble-only',action='store_true',help=argparse.SUPPRESS)
    args=parser.parse_args()
    version=(ROOT/'VERSION').read_text().strip()
    if not (ROOT/'LICENSE').is_file():raise RuntimeError('Choose the public license before creating release artifacts')
    if not __import__('re').fullmatch(r'\d+\.\d+\.\d+',version):raise RuntimeError('Invalid semantic version')
    output=args.output.resolve();output.mkdir(parents=True,exist_ok=True)
    deny=private_tokens(ROOT)
    artifacts=[]
    if args.assemble_only:
        assemble_existing(ROOT,output)
        findings=audit(output,deny)
        if findings:raise RuntimeError('Assembled application privacy audit failed: '+json.dumps(findings))
        print(json.dumps({'data':{'version':version,'assembled':True},'error':None,'meta':{'publish_attempted':False}}));return 0
    source=output/f'leyline-{version}-public'
    export_source(ROOT,source,deny)
    archive=output/f'leyline-{version}-source.tar.gz';archive_source(source,archive);artifacts.append(archive)
    if not args.source_only:
        with tempfile.TemporaryDirectory(prefix='leyline-release-',dir='/tmp') as directory:
            neutral=Path(directory)/'source';shutil.copytree(source,neutral)
            work=Path(directory)/'products';work.mkdir()
            build_application(neutral,work,args.arch,args.sign_identity,args.notary_profile)
            payload=Path(directory)/f'leyline-{version}' ;payload.mkdir()
            for name in ['Leyline.app','Leyline Recovery.app']:shutil.copytree(work/name,payload/name,symlinks=True)
            shutil.copy2(source/'install.sh',payload/'install.sh');shutil.copy2(source/'LICENSE',payload/'LICENSE')
            findings=audit(payload,deny)
            if findings:raise RuntimeError('Application privacy audit failed: '+json.dumps(findings))
            application_archive=output/f'leyline-{version}-macos-{args.arch}.zip'
            run(['/usr/bin/ditto','-c','-k','--keepParent','--norsrc','--noextattr',str(payload),str(application_archive)])
            artifacts.append(application_archive)
    if args.repository:
        artifacts.append(install_recipe(args.repository,version,archive,output))
    else:
        template=install_recipe('https://github.com/OWNER/REPOSITORY',version,archive,output)
        template_path=output/'leyline.rb.in';template.rename(template_path);artifacts.append(template_path)
    if args.anonymous_history:
        anonymous_history(source,version)
        findings=audit(source,deny,fresh_history=True)
        if findings:raise RuntimeError('Anonymous Git audit failed: '+json.dumps(findings))
    checksums=''.join(f'{digest(path)}  {path.name}\n' for path in artifacts)
    (output/'SHA256SUMS').write_text(checksums)
    report={'homebrew_repository_required':not bool(args.repository),'version':version,'artifacts':[p.name for p in artifacts],'public_source':source.name,'anonymous_history':args.anonymous_history,
            'notarized':bool(args.notary_profile),'publisher_identity_in_signature':bool(args.sign_identity),
            'privacy_clean':True,'license':(ROOT/'LICENSE').read_text().splitlines()[0],'published':False}
    (output/'release-report.json').write_text(json.dumps(report,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'data':report,'error':None,'meta':{'publish_attempted':False}},sort_keys=True));return 0

if __name__=='__main__':
    try:raise SystemExit(main())
    except (OSError,RuntimeError,ValueError,AssertionError) as error:
        print(json.dumps({'data':None,'error':{'code':'RELEASE.PREPARATION_FAILED','message':str(error)},'meta':{'publish_attempted':False}}),file=sys.stderr)
        raise SystemExit(1)
