#!/usr/bin/env python3
"""Pinned oracle tool setup fails before executing unverified cache/download data."""
from __future__ import annotations
import os, subprocess, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
HELPER=ROOT/'scripts/development/setup-oracle-jq.sh'
class OracleTool(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='leyline-oracle-tool-');self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.cache=self.root/'cache';self.tools=self.root/'tools';self.tools.mkdir()
        self.marker=self.root/'executed';self.fetch=self.root/'fetched'
        self.env={**os.environ,'PATH':str(self.tools)+':'+os.environ['PATH'],'LEYLINE_ORACLE_JQ_DIR':str(self.cache)}
        (self.tools/'uname').write_text('#!/bin/sh\ncase "$1" in -s) echo Darwin;; -m) echo arm64;; esac\n')
        (self.tools/'uname').chmod(0o755)
        (self.tools/'curl').write_text('#!/bin/sh\nprintf requested > "$ORACLE_TEST_FETCH"\nexit 7\n')
        (self.tools/'curl').chmod(0o755);self.env['ORACLE_TEST_FETCH']=str(self.fetch)
    def run_helper(self,*args):
        return subprocess.run(['/bin/bash',str(HELPER),*args],env=self.env,text=True,capture_output=True)
    def cache_binary(self,data):
        directory=self.cache/'jq-macos-arm64';directory.mkdir(parents=True,mode=0o700);directory.chmod(0o700)
        binary=directory/'jq';binary.write_text(data);binary.chmod(0o700);return binary
    def test_missing_tool_verification_is_offline_and_creates_no_cache(self):
        result=self.run_helper('--verify')
        self.assertEqual(result.returncode,69);self.assertFalse(self.fetch.exists());self.assertFalse(self.cache.exists())
    def test_wrong_cached_binary_is_not_executed_or_automatically_replaced(self):
        binary=self.cache_binary('#!/bin/sh\nprintf ran > "'+str(self.marker)+'"\necho jq-1.8.1\n')
        before=binary.read_bytes();result=self.run_helper('--verify')
        self.assertEqual(result.returncode,65);self.assertIn('checksum mismatch',result.stderr)
        self.assertFalse(self.marker.exists());self.assertFalse(self.fetch.exists());self.assertEqual(binary.read_bytes(),before)
        result=self.run_helper();self.assertEqual(result.returncode,65);self.assertFalse(self.fetch.exists())
    def test_symlink_cache_is_refused_before_execution(self):
        binary=self.cache_binary('wrong');target=self.root/'target';binary.rename(target);binary.symlink_to(target)
        result=self.run_helper('--verify');self.assertEqual(result.returncode,69);self.assertFalse(self.fetch.exists())
    def test_failed_explicit_download_leaves_no_binary_or_staging_file(self):
        result=self.run_helper();self.assertEqual(result.returncode,7);self.assertTrue(self.fetch.exists())
        self.assertFalse((self.cache/'jq-macos-arm64/jq').exists())
        self.assertEqual(list((self.cache/'jq-macos-arm64').glob('.download.*')),[])
    def test_checksum_mismatch_download_is_never_installed_or_executed(self):
        (self.tools/'curl').write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do case "$1" in -o) shift; printf corrupted > "$1"; exit 0;; esac; shift; done\nexit 1\n')
        result=self.run_helper();self.assertEqual(result.returncode,65);self.assertIn('checksum mismatch',result.stderr)
        self.assertFalse((self.cache/'jq-macos-arm64/jq').exists());self.assertFalse(self.marker.exists())
        self.assertEqual(list((self.cache/'jq-macos-arm64').glob('.download.*')),[])
    def test_relative_cache_and_unknown_options_are_usage_errors(self):
        for args in [('--directory','relative'),('--directory',),('--unknown',)]:
            with self.subTest(args=args):self.assertEqual(self.run_helper(*args).returncode,64)
        self.assertFalse(self.fetch.exists())
if __name__=='__main__':unittest.main(verbosity=2)
