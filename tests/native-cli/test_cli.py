#!/usr/bin/env python3
"""Hermetic native CLI, reset, health and installer boundary checks."""
from __future__ import annotations
import json, os, re, subprocess, tempfile, unittest
from pathlib import Path
REPO=Path(__file__).resolve().parents[2]
class NativeCli(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="ley-native-cli-");self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name);self.root=self.directory/"resident root";self.root.mkdir()
        journal=self.root/"state/leylined/journal.jsonl";journal.parent.mkdir(parents=True);journal.write_bytes(b"immutable-test-journal\n")
        self.journal=journal;self.client=self.directory/"native";self.calls=self.directory/"calls"
        self.client.write_text(r"""#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "$NATIVE_CALLS"
printf '%s\0' "$@" >> "$NATIVE_ARGV"
[[ "${NATIVE_FAILURE:-0}" == 0 ]] || exit 65
case "$1" in
 status)
  jq -c --arg mutation "${NATIVE_MUTATION:-}" '{data:(if $mutation=="world" then .world.observation.world_complete=false elif $mutation=="input" then .health.resident.input.tap_installed=false elif $mutation=="projection" then .health.projection.last_rendered_revision=6 elif $mutation=="ownership" then .health.owner="unknown" elif $mutation=="running" then .world.resident_running=false elif $mutation=="active_ids" then .health.resident.input.active_action_ids="invalid" elif $mutation=="schema" then .health.schema=1 elif $mutation=="seed" then .health.world_seed.ready=false elif $mutation=="focus" then .health.focus_observer.ready=false elif $mutation=="shape" then .health.unexpected=true else . end),error:null,meta:{}}' "$NATIVE_STATUS" ;;
 install) cat "$NATIVE_INSTALL_PLAN" ;;
 control) printf '{"data":{"phase":"completed"},"error":null,"meta":{"completed":true}}\n' ;;
 *) printf '{"data":{"args":"native"},"error":null,"meta":{}}\n' ;;
esac
""")
        self.client.chmod(0o755)
        self.env={**os.environ,"LEYLINE_HOME":str(REPO),"LEYLINE_ROOT":str(self.root),"LEYLINE_RESIDENT_CLIENT_BIN":str(self.client),
                  "LEYLINE_DOCTOR_JOBS_FILE":str(REPO/"tests/native-cli/fixtures/jobs.json"),"NATIVE_CALLS":str(self.calls),
                  "NATIVE_ARGV":str(self.directory/"argv"),"NATIVE_STATUS":str(REPO/"tests/native-cli/fixtures/status.json"),"NATIVE_INSTALL_PLAN":str(REPO/"tests/native-cli/fixtures/install-plan.json")}
    def run_cli(self,*args,**extra):
        return subprocess.run(["/bin/bash",str(REPO/"bin/ley"),*args],env={**self.env,**extra},text=True,capture_output=True)
    def test_native_actions_forward_arguments(self):
        self.assertEqual(self.run_cli("act","nav.focus.east","--request-id","fixture").returncode,0)
        self.assertEqual(self.calls.read_text(),"act nav.focus.east --request-id fixture\n")
    def test_native_trace_forwards_to_resident_client(self):
        self.assertEqual(self.run_cli("resident","trace","--args-json",'{"limit":10}').returncode,0)
        self.assertEqual(self.calls.read_text(),'trace --args-json {"limit":10}\n')
    def test_native_trace_client_failure_is_visible(self):
        self.assertEqual(self.run_cli("resident","trace",NATIVE_FAILURE="1").returncode,65)
    def test_command_names_reject_paths_and_removed_family(self):
        for name in ["../act","/tmp/foo","action-run","parcel","core","perf","trace","validate"]:
            with self.subTest(name=name):self.assertEqual(self.run_cli(name).returncode,64)
        self.assertFalse(self.calls.exists())
    def test_missing_client_fails_without_fallback(self):
        # Every socket-backed command stops at 69 with its own message on its own stream; none falls back.
        absent=str(self.directory/"absent")
        envelope='{"data":null,"error":{"code":"core_client_unavailable","message":"Build the resident command client"},"meta":{"transport":"resident_socket"}}\n'
        for args,stdout,stderr in [(("act","nav.focus.east"),envelope,""),(("resident","health"),envelope,""),
                                   (("ctl","start"),"","error resident control client unavailable\n"),
                                   (("ctl","reset"),"","error resident reset client unavailable\n"),
                                   (("setup","launchd","install","--plan"),"","error native installer unavailable\n"),
                                   (("doctor",),"","error resident client unavailable; native health unverified\n")]:
            with self.subTest(command=" ".join(args)):
                result=self.run_cli(*args,LEYLINE_RESIDENT_CLIENT_BIN=absent)
                self.assertEqual((result.returncode,result.stdout,result.stderr),(69,stdout,stderr))
        self.assertFalse(self.calls.exists())
    def test_reset_dry_run_preserves_journal_and_never_calls_owner(self):
        result=self.run_cli("ctl","reset","--dry-run");self.assertEqual(result.returncode,0)
        self.assertIn(str(self.journal),result.stdout);self.assertFalse(self.calls.exists())
        self.assertEqual(self.journal.read_bytes(),b"immutable-test-journal\n")
    def test_reset_hard_has_one_native_request_and_keeps_journal_bytes(self):
        result=self.run_cli("ctl","reset","--hard","--no-restart");self.assertEqual(result.returncode,0)
        lines=self.calls.read_text().splitlines();self.assertEqual(len(lines),1)
        self.assertIn('control reset --args-json {"mode":"hard","resume":false} --wait --timeout-seconds 8',lines[0])
        self.assertEqual(self.journal.read_bytes(),b"immutable-test-journal\n")
    def test_reset_preserves_client_error(self):self.assertEqual(self.run_cli("ctl","reset",NATIVE_FAILURE="1").returncode,65)
    def test_reset_rejects_unknown_external_scope(self):
        self.assertEqual(self.run_cli("ctl","reset","--include-external").returncode,64);self.assertFalse(self.calls.exists())
    def test_source_checkout_refuses_package_install(self):
        self.assertEqual(self.run_cli("install","--start").returncode,64);self.assertFalse(self.calls.exists())
    def test_native_health_complete(self):
        result=self.run_cli("doctor");self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn("resident diagnostics passed",result.stdout)
    def test_disabled_space_allows_only_the_control_chord(self):
        status=json.loads((REPO/"tests/native-cli/fixtures/status.json").read_text())
        status["world"]["focus"]["space_enabled"]=False
        facts=status["health"]["resident"]["input"]
        facts.update(claims_allowed=False,space_control_allowed=True,accepting_claims=True,
                     active_action_ids=["space.management.toggle"])
        path=self.directory/"off-status.json";path.write_text(json.dumps(status))
        result=self.run_cli("doctor",NATIVE_STATUS=str(path))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        facts["active_action_ids"].append("nav.focus.east");path.write_text(json.dumps(status))
        self.assertNotEqual(self.run_cli("doctor",NATIVE_STATUS=str(path)).returncode,0)
    def test_health_mutants_fail(self):
        for mutation in ["world","input","projection","ownership","schema","seed","focus","shape","running","active_ids"]:
            with self.subTest(mutation=mutation):self.assertNotEqual(self.run_cli("doctor",NATIVE_MUTATION=mutation).returncode,0)
    def test_health_transport_failure_fails(self):self.assertNotEqual(self.run_cli("doctor",NATIVE_FAILURE="1").returncode,0)
    def test_health_pid_mismatch_fails(self):
        jobs=json.loads((REPO/"tests/native-cli/fixtures/jobs.json").read_text());jobs["leylined"]["pid"]=9999
        path=self.directory/"jobs.json";path.write_text(json.dumps(jobs))
        self.assertNotEqual(self.run_cli("doctor",LEYLINE_DOCTOR_JOBS_FILE=str(path)).returncode,0)
    def test_health_extra_job_fact_fails(self):
        jobs=json.loads((REPO/"tests/native-cli/fixtures/jobs.json").read_text());jobs["unknown"]={"registered":True,"pid":8888}
        path=self.directory/"jobs.json";path.write_text(json.dumps(jobs))
        self.assertNotEqual(self.run_cli("doctor",LEYLINE_DOCTOR_JOBS_FILE=str(path)).returncode,0)
    def test_globally_off_health_requires_released_capabilities(self):
        status=json.loads((REPO/"tests/native-cli/fixtures/status.json").read_text())
        status["world"].update(management_enabled=False,resident_running=False)
        status["world"]["observation"]["world_complete"]=False
        status["health"]["focus_observer"].update(ready=False,window_notifications_ready=False)
        status["health"]["resident"]["input"].update(tap_installed=False,desired_running=False,
          claims_allowed=False,space_control_allowed=False,accepting_claims=False,active_action_ids=[])
        status["health"]["projection"].update(mounted=False,last_rendered_revision=None)
        path=self.directory/"off-health.json";path.write_text(json.dumps(status))
        result=self.run_cli("doctor",NATIVE_STATUS=str(path))
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        status["health"]["resident"]["input"]["tap_installed"]=True;path.write_text(json.dumps(status))
        self.assertNotEqual(self.run_cli("doctor",NATIVE_STATUS=str(path)).returncode,0)
    def test_installer_plan_forwards_once_and_preserves_root(self):
        launch_agents=self.directory/"launch agents"
        result=self.run_cli("setup","launchd","install","--plan","--no-start","--root",str(self.root),"--launch-agents",str(launch_agents))
        self.assertEqual(result.returncode,0,result.stderr)
        envelope=json.loads(result.stdout);self.assertEqual(envelope["meta"]["transport"],"native_installation")
        data=envelope["data"];self.assertFalse(data["applied"]);self.assertTrue(data["plan"])
        self.assertEqual(data["plist"]["Label"],"org.leyline.leylined")
        self.assertEqual(data["plist"]["ThrottleInterval"],1);self.assertTrue(data["plist"]["KeepAlive"])
        self.assertEqual(self.calls.read_text().splitlines(),[f"install --plan --no-start --root {self.root} --launch-agents {launch_agents}"])
        actual_args=(self.directory/"argv").read_bytes().rstrip(b"\0").split(b"\0")
        self.assertEqual([arg.decode() for arg in actual_args],["install","--plan","--no-start","--root",str(self.root),"--launch-agents",str(launch_agents)])
        self.assertFalse(launch_agents.exists());self.assertEqual(self.journal.read_bytes(),b"immutable-test-journal\n")
    def test_setup_default_inspects_native_service(self):
        self.assertEqual(self.run_cli("setup").returncode,0)
        self.assertEqual(self.calls.read_text(),"service-status\n")
    def test_setup_unknown_operation_never_dispatches(self):
        self.assertEqual(self.run_cli("setup","launchd","obsolete").returncode,64);self.assertFalse(self.calls.exists())
    def test_setup_native_failure_is_visible(self):
        self.assertEqual(self.run_cli("setup","launchd","install","--plan",NATIVE_FAILURE="1").returncode,65)
    def test_setup_missing_native_installer_is_visible(self):
        self.assertEqual(self.run_cli("setup","launchd","install","--plan",LEYLINE_RESIDENT_CLIENT_BIN=str(self.directory/"absent")).returncode,69)
    def test_native_suite_uses_isolated_developer_runner(self):
        home=self.directory/"source home";(home/"bin").mkdir(parents=True)
        runner=home/"bin/leylined-tests"
        runner.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$NATIVE_CALLS"\n');runner.chmod(0o755)
        production=home/"bin/leylined";production.write_text('#!/bin/bash\nexit 98\n');production.chmod(0o755)
        command='wm_head() { :; }; wm_err() { printf "%s\\n" "$*" >&2; }; source "$SOURCE_TEST_COMMAND"; test_native'
        result=subprocess.run(["/bin/bash","-c",command],env={**self.env,"LEYLINE_HOME":str(home),"LEYLINE_CORE_BIN":"","SOURCE_TEST_COMMAND":str(REPO/"commands/test.sh")},text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        # Exactly the listed suites, once each, in order, on the isolated runner (source_checks pins the list against main.swift).
        suites=re.search(r"(?m)^\s*for suite in (.+?); do",(REPO/"commands/test.sh").read_text()).group(1).split()
        self.assertEqual(self.calls.read_text().splitlines(),[f"self-test {suite}" for suite in suites])
    def test_recovery_suite_uses_isolated_developer_runner(self):
        home=self.directory/"source home";(home/"bin").mkdir(parents=True)
        runner=home/"bin/Leyline Recovery Tests.app/Contents/MacOS/leyline-recovery"
        runner.parent.mkdir(parents=True)
        runner.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$NATIVE_CALLS"\n');runner.chmod(0o755)
        guard=home/"bin/leyline-grant-free-check"
        guard.write_text('#!/bin/bash\nexit 0\n');guard.chmod(0o755)
        command='wm_err() { printf "%s\\n" "$*" >&2; }; source "$SOURCE_TEST_COMMAND"; test_recovery'
        result=subprocess.run(["/bin/bash","-c",command],env={**self.env,"LEYLINE_HOME":str(home),"LEYLINE_RECOVERY_BIN":"","SOURCE_TEST_COMMAND":str(REPO/"commands/test.sh")},text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.calls.read_text().splitlines(),["--self-test-core","--disable --plan"])
    def test_release_suite_supplies_default_developer_runner(self):
        home=self.directory/"source home";corpus=home/"tests/release";corpus.mkdir(parents=True)
        (corpus/"test_runner.py").write_text('import os, unittest\nfrom pathlib import Path\nclass Runner(unittest.TestCase):\n    def test_selected(self):\n        self.assertEqual(os.environ["LEYLINE_CORE_BIN"], str(Path(os.environ["LEYLINE_HOME"])/"bin/leylined-tests"))\n')
        command='wm_err() { printf "%s\\n" "$*" >&2; }; source "$SOURCE_TEST_COMMAND"; test_release'
        result=subprocess.run(["/bin/bash","-c",command],env={**self.env,"LEYLINE_HOME":str(home),"LEYLINE_CORE_BIN":"","SOURCE_TEST_COMMAND":str(REPO/"commands/test.sh")},text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
if __name__=="__main__":unittest.main(verbosity=2)
