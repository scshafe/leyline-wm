#!/usr/bin/env python3
"""Outer app-copy transaction tests with fake native service administration."""
from __future__ import annotations
import os,plistlib,subprocess,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
NATIVE='''#!/usr/bin/env bash
set -eu
version="$(cat "$(dirname "$0")/../version-marker")"
printf '%s %s home=%s\\n' "$1" "$version" "${LEYLINE_HOME:-unset}" >> "$INSTALLER_TEST_LOG"
case "$1" in
 service-status) printf '{"data":{"registered":%s},"error":null}\\n' "${INSTALLER_TEST_REGISTERED:-false}" ;;
 install) [[ "${INSTALLER_TEST_FAIL_INSTALL:-0}" == 0 ]] || exit 66 ;;
 service-restart) [[ "${INSTALLER_TEST_FAIL_RESTART:-0}" == 0 ]] || exit 67 ;;
esac
'''
class ArchiveInstaller(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='leyline-archive-install-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name).resolve();self.source=self.root/'download';self.source.mkdir()
        self.apps=self.root/'Applications';self.bin=self.root/'bin';self.tools=self.root/'tools';self.tools.mkdir()
        (self.tools/'codesign').write_text('#!/bin/sh\nexit 0\n');(self.tools/'codesign').chmod(0o755)
        self.log=self.root/'calls';self.env={**os.environ,'PATH':str(self.tools)+':/usr/bin:/bin','INSTALLER_TEST_LOG':str(self.log),'LEYLINE_HOME':str(self.source/'wrong-source-resources')}
        (self.source/'install.sh').write_bytes((ROOT/'install.sh').read_bytes())
        self.make_apps(self.source,'new')
    def make_apps(self,parent,version):
        for name,identifier in [('Leyline.app','org.leyline'),('Leyline Recovery.app','org.leyline.recovery')]:
            contents=parent/name/'Contents';(contents/'MacOS').mkdir(parents=True)
            (contents/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier}))
            (contents/'version-marker').write_text(version)
            exe=contents/'MacOS/leylined';exe.write_text(NATIVE);exe.chmod(0o755)
    def run_installer(self,*args,**extra):
        return subprocess.run(['/bin/bash',str(self.source/'install.sh'),'--application-dir',str(self.apps),'--bin-dir',str(self.bin),'--no-start',*args],env={**self.env,**extra},text=True,capture_output=True)
    def test_fresh_copy_uses_installed_resources_and_no_start(self):
        result=self.run_installer();self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('install new home=unset',self.log.read_text());self.assertTrue((self.bin/'ley').is_symlink())
    def test_unrelated_cli_is_refused_before_app_copy(self):
        self.bin.mkdir();(self.bin/'ley').write_text('unrelated')
        result=self.run_installer();self.assertNotEqual(result.returncode,0)
        self.assertFalse((self.apps/'Leyline.app').exists());self.assertFalse(self.log.exists())
    def test_failed_install_restores_old_apps_before_restarting_prior_job(self):
        self.apps.mkdir();self.make_apps(self.apps,'old')
        result=self.run_installer('--update',INSTALLER_TEST_REGISTERED='true',INSTALLER_TEST_FAIL_INSTALL='1')
        self.assertEqual(result.returncode,66,result.stderr)
        self.assertEqual((self.apps/'Leyline.app/Contents/version-marker').read_text(),'old')
        self.assertIn('service-restart old home=unset',self.log.read_text())
    def test_failed_rollback_restart_is_explicit(self):
        self.apps.mkdir();self.make_apps(self.apps,'old')
        result=self.run_installer('--update',INSTALLER_TEST_REGISTERED='true',INSTALLER_TEST_FAIL_INSTALL='1',INSTALLER_TEST_FAIL_RESTART='1')
        self.assertEqual(result.returncode,70);self.assertIn('prior service restart failed',result.stderr)
    def test_shared_writable_ancestor_is_refused_before_copy(self):
        parent=self.root/'shared';parent.mkdir();parent.chmod(0o777);self.apps=parent/'Applications'
        result=self.run_installer();self.assertNotEqual(result.returncode,0)
        self.assertFalse(self.apps.exists());self.assertFalse(self.log.exists())
    def test_symlink_ancestor_is_refused_before_copy(self):
        actual=self.root/'real';actual.mkdir();link=self.root/'link';link.symlink_to(actual);self.apps=link/'Applications'
        result=self.run_installer();self.assertNotEqual(result.returncode,0)
        self.assertFalse((actual/'Applications').exists());self.assertFalse(self.log.exists())

if __name__=='__main__':unittest.main(verbosity=2)
