#!/usr/bin/env python3
"""Release export privacy, reproducibility and anonymous provenance regressions."""
from __future__ import annotations
import hashlib, importlib.util, json, os, plistlib, subprocess, sys, tarfile, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts/release'))
from privacy_audit import audit,private_tokens
from package_release import export_source,archive_source,anonymous_history,source_files,install_recipe,app_shell,app_resources

class Packaging(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='leyline-package-test-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.repo=self.root/'repo';self.repo.mkdir()
        subprocess.run(['git','init','-q',str(self.repo)],check=True)
        for name,data in {'README.md':'Project\n','VERSION':'1.0.0\n','LICENSE':'MIT License\n','keymap/global.json':'{}\n','leylined/Sources/Example.swift':'import Foundation\n','runtime/state.json':'private state','notes.private.txt':'private notes','.claude/handoff.local.md':'private handoff','bin/leylined':b'\xcf\xfa\xed\xfeprivate'}.items():
            path=self.repo/name;path.parent.mkdir(parents=True,exist_ok=True)
            path.write_bytes(data if isinstance(data,bytes) else data.encode())
        self.track()
    def track(self):
        # Export reads tracked files; private paths are staged to prove the filters still apply.
        subprocess.run(['git','add','-A'],cwd=self.repo,check=True)
    def test_export_excludes_history_runtime_work_notes_and_binaries(self):
        dest=self.root/'public';export_source(self.repo,dest,set())
        self.assertTrue((dest/'VERSION').is_file())
        for name in ['.git','.claude','runtime','notes.private.txt','bin/leylined']:self.assertFalse((dest/name).exists())
    def test_export_excludes_untracked_source_files(self):
        (self.repo/'docs').mkdir();(self.repo/'docs/draft.md').write_text('untracked draft\n')
        dest=self.root/'public';export_source(self.repo,dest,set())
        self.assertTrue((dest/'README.md').is_file());self.assertFalse((dest/'docs/draft.md').exists())
    def test_failed_privacy_gate_publishes_no_destination(self):
        bad='/'+ '/'.join(['Users','fixture-account','work'])
        (self.repo/'README.md').write_text(bad)
        dest=self.root/'public'
        with self.assertRaisesRegex(RuntimeError,'privacy audit'):export_source(self.repo,dest,set())
        self.assertFalse(dest.exists())
    def test_personal_file_name_is_rejected_even_when_content_is_empty(self):
        (self.repo/'docs').mkdir();(self.repo/'docs/fixture-person.md').write_text('');self.track()
        with self.assertRaises(RuntimeError):export_source(self.repo,self.root/'public',{'fixture-person'})
    def test_export_refuses_source_symlinks(self):
        (self.repo/'docs').mkdir();(self.repo/'docs/link.md').symlink_to('/etc/passwd');self.track()
        with self.assertRaisesRegex(RuntimeError,'symlink'):export_source(self.repo,self.root/'public',set())
    def test_source_archive_is_reproducible_without_owner_metadata(self):
        dest=self.root/'leyline-1.0.0';export_source(self.repo,dest,set())
        a=self.root/'a.tar.gz';b=self.root/'b.tar.gz';archive_source(dest,a);archive_source(dest,b)
        self.assertEqual(a.read_bytes(),b.read_bytes())
        with tarfile.open(a) as archive:
            self.assertTrue(all(row.uid==0 and row.gid==0 and row.mtime==0 and not row.uname and not row.gname for row in archive.getmembers()))
    def test_fresh_history_has_one_generic_commit_no_private_remotes(self):
        dest=self.root/'public';export_source(self.repo,dest,set());anonymous_history(dest,'1.0.0')
        def git(*args):return subprocess.check_output(['git',*args],cwd=dest,text=True).strip()
        self.assertEqual(git('rev-list','--count','HEAD'),'1')
        self.assertEqual(git('log','-1','--format=%an <%ae>'),'Leyline Contributors <contributors@leyline.invalid>')
        self.assertEqual(git('remote'),'');self.assertEqual(git('tag'),'v1.0.0')
        self.assertEqual(audit(dest,fresh_history=True),[])
        subprocess.run(['git','remote','add','origin','https://example.invalid/private'],cwd=dest,check=True)
        self.assertEqual(audit(dest,fresh_history=True)[0]['code'],'nonanonymous_or_extra_git_history')
    def test_public_checkout_does_not_deny_generic_identity_or_project_owner(self):
        dest=self.root/'public';export_source(self.repo,dest,set());anonymous_history(dest,'1.0.0')
        self.assertNotIn('contributors@leyline.invalid',private_tokens(dest))
        subprocess.run(['git','remote','add','origin','https://github.com/leyline/project'],cwd=dest,check=True)
        self.assertNotIn('leyline',private_tokens(dest))
        subprocess.run(['git','config','--unset','user.name'],cwd=dest,check=True)
        self.assertNotIn('leyline',private_tokens(dest))

    def test_git_does_not_enter_source_archive_after_public_init(self):
        dest=self.root/'public';export_source(self.repo,dest,set());anonymous_history(dest,'1.0.0')
        output=self.root/'source.tar.gz';archive_source(dest,output)
        with tarfile.open(output) as archive:self.assertFalse(any('/.git/' in m.name for m in archive.getmembers()))
    def test_internal_app_symlink_is_accepted_external_symlink_is_not(self):
        app=self.root/'app';app.mkdir();(app/'binary').write_text('safe');(app/'link').symlink_to('binary')
        self.assertEqual(audit(app),[])
        (app/'link').unlink();(app/'link').symlink_to('/etc/passwd')
        self.assertEqual(audit(app)[0]['code'],'external_or_dangling_symlink')
    def test_geometry_anchor_is_not_an_email_but_real_email_is_rejected(self):
        tree=self.root/'anchors';tree.mkdir();path=tree/'data.txt'
        path.write_text('v@960.hi h@600.lo')
        self.assertEqual(audit(tree),[])
        path.write_text('person'+'@'+'private-domain.edu')
        self.assertEqual(audit(tree)[0]['code'],'personal_email')
    def test_app_shell_stamps_version_and_accepts_an_existing_shell(self):
        template=self.root/'Template.plist';template.write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.leyline','CFBundleShortVersionString':'0.0.0','CFBundleVersion':'0'}))
        app=self.root/'Leyline.app';(app/'Contents/MacOS').mkdir(parents=True)
        self.assertEqual(app_shell(template,app,'1.0.0'),app)
        plist=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        self.assertEqual((plist['CFBundleIdentifier'],plist['CFBundleShortVersionString'],plist['CFBundleVersion']),('org.leyline','1.0.0','1.0.0'))
        app_shell(template,app,'1.0.1');self.assertEqual(plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleVersion'],'1.0.1')
    def test_app_resources_layout_is_where_ley_finds_the_package_installer(self):
        # The real bin/ley and lib ride along; from the bundled home, `ley install` must climb to install.sh beside the apps.
        for name in ['lib/cli_output.sh','bin/ley']:
            target=self.repo/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/name).read_bytes());target.chmod(0o755)
        (self.repo/'commands').mkdir()
        for name in ['act','resident','ctl','doctor','setup']:(self.repo/f'commands/{name}.sh').write_text('#!/usr/bin/env bash\n')
        package=self.root/'leyline-1.0.0';app=package/'Leyline.app';(app/'Contents/MacOS').mkdir(parents=True)
        home=app_resources(self.repo,app,'1.0.0')
        self.assertEqual(home,app/'Contents/Resources/leyline')
        self.assertEqual(json.loads((home/'release.json').read_text()),{'version':'1.0.0','profile':'application'})
        self.assertEqual(os.readlink(home/'bin/leylined'),'../../../MacOS/leylined')
        self.assertEqual({p.name for p in (home/'commands').iterdir()},{'act.sh','resident.sh','ctl.sh','doctor.sh','setup.sh'})
        (package/'Leyline Recovery.app').mkdir();log=self.root/'installer-calls'
        (package/'install.sh').write_text('#!/bin/bash\nprintf "%s\\n" "$*" > "$INSTALLER_LOG"\n')
        env={key:value for key,value in os.environ.items() if key!='LEYLINE_HOME'};env['INSTALLER_LOG']=str(log)
        result=subprocess.run(['/bin/bash',str(home/'bin/ley'),'install','--start'],env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr);self.assertEqual(log.read_text(),'--start\n')
    def test_recipe_is_checksum_bound_to_concrete_repository(self):
        archive=self.root/'leyline-1.0.0-source.tar.gz';archive.write_bytes(b'source')
        recipe=install_recipe('https://github.com/example-project/leyline','1.0.0',archive,self.root)
        data=recipe.read_text();self.assertIn(hashlib.sha256(b'source').hexdigest(),data)
        self.assertIn('/releases/download/v1.0.0/leyline-1.0.0-source.tar.gz',data)
        with self.assertRaises(RuntimeError):install_recipe('http://example.invalid/unsafe','1.0.0',archive,self.root)

    def test_recipe_refuses_ruby_interpolation_and_non_slug_urls(self):
        archive=self.root/'source.tar.gz';archive.write_bytes(b'source')
        for value in ['https://github.com/owner/repo#{system("bad")}', 'https://github.com/owner/repo%22', 'https://github.com/owner/repo\n', 'https://github.com/user'+'@'+'github.com/repo', 'https://github.com/owner/repo?x=1', 'https://github.com/owner/.', 'https://github.com/owner/..']:
            with self.subTest(url=value), self.assertRaises(RuntimeError):install_recipe(value,'1.0.0',archive,self.root)

    def test_declared_public_owner_only_permits_project_urls_and_tap_commands(self):
        policy=self.repo/'packaging/release-policy.json';policy.parent.mkdir()
        policy.write_text(json.dumps({'public_repository':'https://github.com/fixture-owner/project','homebrew_repository':'https://github.com/fixture-owner/homebrew-tap'}))
        readme=self.repo/'README.md'
        readme.write_text('https://github.com/fixture-owner/project\nhttps://github.com/fixture-owner/project/releases/tag/v1.0.0\nhttps://github.com/fixture-owner/homebrew-tap\nbrew install fixture-owner/tap/leyline\n')
        self.track()
        # Audit the exported tree so private runtime/build material is excluded.
        dest=self.root/'public';export_source(self.repo,dest,{'fixture-owner'})
        self.assertEqual(audit(dest,{'fixture-owner'}),[])
        (dest/'README.md').write_text('fixture-owner uses a private directory')
        self.assertTrue(any(f['code']=='personal_identifier' for f in audit(dest,{'fixture-owner'})))
        for text in ['https://github.com/fixture-owner/project-secret','fixture-owner/tap-secrets']:
            (dest/'README.md').write_text(text)
            self.assertTrue(any(f['code']=='personal_identifier' for f in audit(dest,{'fixture-owner'})))

    def test_public_owner_does_not_permit_home_paths_or_email(self):
        policy=self.repo/'packaging/release-policy.json';policy.parent.mkdir()
        policy.write_text(json.dumps({'public_repository':'https://github.com/fixture-owner/project'}));self.track()
        dest=self.root/'public';export_source(self.repo,dest,{'fixture-owner'})
        (dest/'README.md').write_text('/'+'/'.join(['Users','fixture-owner','secret'])+' fixture-owner'+'@'+'private-domain.edu')
        codes={f['code'] for f in audit(dest,{'fixture-owner'})}
        self.assertTrue({'absolute_home_path','personal_email','personal_identifier'}<=codes)

if __name__=='__main__':unittest.main(verbosity=2)
