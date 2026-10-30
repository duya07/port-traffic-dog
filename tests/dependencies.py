#!/usr/bin/env python3
"""Public CLI dependency contracts, with isolated fake package-manager boundaries."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

PRODUCT = Path(__file__).resolve().parents[1] / "port-traffic-dog.sh"
REAL_PYTHON = sys.executable
MANAGER = r'''
import json,os,sys
from pathlib import Path
state=Path(os.environ['FAKE_PACKAGE_STATE'])
r=json.loads(state.read_text());name=Path(sys.argv[0]).name;args=sys.argv[1:]
if name=='python3':
    raise SystemExit(0 if 'libnetfilter-queue1' in r['installed'] and r.get('mode')!='broken' else 1)
if name=='dpkg-query':
    if '--' not in args:
        for p in sorted(set(r['installed']+r.get('unconfigured',[]))):
            status='unpacked' if p in r.get('unconfigured',[]) else 'installed'
            if any('Pre-Depends' in a for a in args):print(p+'\t'+status+'\t'+r.get('dependencies',{}).get(p,''))
            else:print(p+'\t'+status+'\tno\tno')
        raise SystemExit(0)
    p=args[args.index('--')+1]
    if p not in r['installed'] and p not in r.get('unconfigured',[]):raise SystemExit(1)
    if any('Essential' in a for a in args):print('no\tno')
    else:print('unpacked' if p in r.get('unconfigured',[]) else 'installed')
    raise SystemExit(0)
assert name=='apt-get'
r['calls'].append(args);state.write_text(json.dumps(r))
if 'update' in args:raise SystemExit(41 if r.get('mode')=='index_fail' else 0)
packages=args[args.index('--')+1:]
if 'install' in args:
    planned=sorted(set(packages+['libnfnetlink0','libmnl0'])-set(r['installed']))
    if '--simulate' in args:
        for p in planned:print('Inst '+p+' (1.0 repository [amd64])')
        raise SystemExit(0)
    if r.get('mode')=='partial':
        r['installed'].append(planned[0]);state.write_text(json.dumps(r));raise SystemExit(42)
    if r.get('mode')=='partial_unconfigured':
        r['installed'].append(planned[0]);r['unconfigured']=[planned[1]]
        state.write_text(json.dumps(r));raise SystemExit(42)
    if r.get('mode')!='no_effect':r['installed']=sorted(set(r['installed']+planned))
    state.write_text(json.dumps(r));raise SystemExit(0)
assert 'remove' in args
if '--simulate' in args:
    if r.get('mode')=='cascade':packages+=['unrelated-server']
    for p in packages:print('Remv '+p+' [1.0]')
    raise SystemExit(0)
r['installed']=[p for p in r['installed'] if p not in packages]
state.write_text(json.dumps(r))
'''


class DependencyFlow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="dog-dependency-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.ledger = self.root / "ledger"
        self.config = self.root / "config"
        self.installed = self.root / "installed-dog.sh"
        text = PRODUCT.read_text()
        for old, new in {
            'readonly CONFIG_DIR="/etc/port-traffic-dog"': f'readonly CONFIG_DIR="{self.config}"',
            'readonly INSTALLED_SCRIPT_PATH="/usr/local/bin/port-traffic-dog.sh"': f'readonly INSTALLED_SCRIPT_PATH="{self.installed}"',
            'readonly IP_GUARD_SERVICE_FILE="/etc/systemd/system/port-traffic-dog-ip-guard.service"': f'readonly IP_GUARD_SERVICE_FILE="{self.root}/guard.service"',
            '/etc/trafficcop-lite/': str(self.root / "ntc") + '/',
            '/usr/local/bin/ntc': str(self.root / "ntc-command"),
        }.items():
            if old in text:
                text = text.replace(old, new)
        self.script = self.root / "dog.sh"
        self.script.write_text(text)
        self.state = self.root / "state.json"
        self.state.write_text(json.dumps({"installed": ["bash", "coreutils", "jq", "python3", "ca-certificates"], "calls": []}))
        # Expose required command names; only the NFQUEUE runtime is initially missing.
        tools = ["cat", "awk", "realpath", "stat", "chmod", "mkdir", "mv", "cp", "rm", "mktemp", "sort", "sed", "grep", "comm", "install", "flock", "cut", "date", "dirname"]
        for tool in tools:
            os.symlink(shutil.which(tool), self.bin / tool)
        for tool in ["nft", "ip", "tc", "ss", "jq", "bc", "unzip", "cron", "crontab", "curl", "conntrack", "pgrep", "modprobe"]:
            if not (self.bin / tool).exists():os.symlink(shutil.which("true"), self.bin / tool)
        for name in ["dpkg-query", "apt-get", "python3"]:
            target = self.bin / name
            target.write_text("#!" + REAL_PYTHON + "\n" + MANAGER)
            target.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin), FAKE_PACKAGE_STATE=str(self.state), PORT_TRAFFIC_DOG_DEPENDENCY_STATE_DIR=str(self.ledger))

    def run_cli(self, *args, input=""):
        return subprocess.run(["/bin/bash", str(self.script), "--dependencies", *args], env=self.env,
                              input=input, text=True, capture_output=True, timeout=15)

    def data(self):
        return json.loads(self.state.read_text())

    def mode(self, value):
        data=self.data();data["mode"]=value;self.state.write_text(json.dumps(data))

    def owned(self):
        return set((self.ledger / "installed-packages").read_text().splitlines())

    def test_report_is_readonly_and_names_missing_runtime(self):
        result=self.run_cli("check")
        self.assertEqual(result.returncode,1,result.stdout+result.stderr)
        self.assertIn("[缺失] libnetfilter-queue1",result.stdout)
        self.assertFalse(self.ledger.exists())
        self.assertFalse(self.config.exists())
        self.assertEqual(self.data()["calls"],[])

    def test_install_only_new_planned_packages_and_repeat(self):
        result=self.run_cli("install","--yes")
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.owned(),{"libnetfilter-queue1","libnfnetlink0","libmnl0"})
        self.assertEqual(self.ledger.stat().st_mode & 0o777,0o700)
        self.assertEqual((self.ledger/"installed-packages").stat().st_mode & 0o777,0o600)
        count=len(self.data()["calls"])
        self.assertEqual(self.run_cli("install","--yes").returncode,0)
        self.assertEqual(len(self.data()["calls"]),count)
        self.assertEqual(self.run_cli("check").returncode,0)
        self.assertEqual(set(self.run_cli("owned").stdout.splitlines()),self.owned())
        self.assertFalse((self.ledger/"pending-before").exists())

    def test_install_cancel_does_not_mutate_packages_or_ledger(self):
        result=self.run_cli("install",input="n\n")
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.data()["calls"],[])
        self.assertFalse(self.ledger.exists())

    def test_partial_install_records_only_actual_success(self):
        self.mode("partial")
        result=self.run_cli("install","--yes")
        self.assertEqual(result.returncode,42,result.stdout+result.stderr)
        self.assertEqual(self.owned(),{"libmnl0"})
        self.assertNotIn("libnetfilter-queue1",self.data()["installed"])

    def test_incomplete_packages_keep_pending_evidence(self):
        self.mode('partial_unconfigured')
        result=self.run_cli('install','--yes')
        self.assertNotEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.owned(),{'libmnl0'})
        self.assertTrue((self.ledger/'pending-before').exists())
        self.assertTrue((self.ledger/'pending-plan').exists())
        self.assertNotEqual(self.run_cli('remove','--yes').returncode,0)

    def test_successful_package_exit_requires_runtime_recheck(self):
        self.mode("no_effect")
        result=self.run_cli("install","--yes")
        self.assertNotEqual(result.returncode,0)
        self.assertIn("复检失败",result.stderr)

    def test_installed_but_broken_library_is_not_reclaimed(self):
        data=self.data();data["installed"].append("libnetfilter-queue1");self.state.write_text(json.dumps(data));self.mode("broken")
        result=self.run_cli("install","--yes")
        self.assertNotEqual(result.returncode,0)
        self.assertIn("[异常] libnetfilter-queue1",result.stdout)
        self.assertEqual(self.data()["calls"],[])

    def test_pending_transaction_refuses_install(self):
        self.ledger.mkdir(mode=0o700)
        pending=self.ledger/"pending-before";pending.write_text("jq\n");pending.chmod(0o600)
        result=self.run_cli("install","--yes")
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.data()["calls"],[])

    def test_pending_transaction_refuses_success_when_tools_are_ready(self):
        data=self.data();data['installed'].append('libnetfilter-queue1');self.state.write_text(json.dumps(data))
        self.ledger.mkdir(mode=0o700)
        pending=self.ledger/'pending-before';pending.write_text('jq\n');pending.chmod(0o600)
        self.assertNotEqual(self.run_cli('check').returncode,0)
        self.assertNotEqual(self.run_cli('install','--yes').returncode,0)
        self.assertTrue(pending.exists())
        self.assertEqual(self.data()['calls'],[])

    def test_uninstall_preserves_preexisting_and_requires_plan_confirmation(self):
        self.assertEqual(self.run_cli("install","--yes").returncode,0)
        result=self.run_cli("remove",input="n\n")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("libnetfilter-queue1",self.data()["installed"])
        result=self.run_cli("remove","--yes")
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.data()["installed"],["bash","ca-certificates","coreutils","jq","python3"])
        self.assertEqual(self.owned(),set())

    def test_out_of_scope_cascade_is_rejected(self):
        self.assertEqual(self.run_cli("install","--yes").returncode,0)
        self.mode("cascade")
        result=self.run_cli("remove","--yes")
        self.assertNotEqual(result.returncode,0)
        self.assertIn("额外删除",result.stderr)
        self.assertFalse(any("remove" in c and "--simulate" not in c for c in self.data()["calls"]))

    def test_removal_refuses_installed_application(self):
        self.installed.touch()
        result=self.run_cli("remove","--yes")
        self.assertNotEqual(result.returncode,0)
        self.assertIn("请先卸载脚本",result.stderr)
        self.assertEqual(self.data()["calls"],[])

    def test_protected_component_dependencies_are_retained(self):
        self.assertEqual(self.run_cli("install","--yes").returncode,0)
        data=self.data();data['installed'].append('systemd');data['dependencies']={'systemd':'libmnl0 (>= 1)'}
        self.state.write_text(json.dumps(data))
        with (self.ledger/'installed-packages').open('a') as log:log.write('systemd\n')
        result=self.run_cli('remove','--yes')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('libmnl0',self.data()['installed'])
        self.assertIn('systemd',self.data()['installed'])
        self.assertNotIn('libnetfilter-queue1',self.data()['installed'])

    def test_ntc_peer_retains_shared_bc(self):
        self.assertEqual(self.run_cli('install','--yes').returncode,0)
        peer=self.root/'ntc';peer.mkdir();(peer/'trafficcop-lite.sh').touch()
        data=self.data();data['installed'].append('bc');self.state.write_text(json.dumps(data))
        with (self.ledger/'installed-packages').open('a') as log:log.write('bc\n')
        result=self.run_cli('remove','--yes')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('bc',self.data()['installed'])
        self.assertIn('bc',self.owned())

    def test_non_apt_missing_runtime_cannot_report_success(self):
        command='source <(sed \'$d\' "$1"); command() { if [ "$1" = -v ] && { [ "$2" = dpkg-query ] || [ "$2" = apt-get ]; }; then return 1; fi; builtin command "$@"; }; if dependency_install_missing true all; then exit 99; fi'
        result=subprocess.run(['/bin/bash','-c',command,'test',str(self.script)],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(self.ledger.exists())

    def test_unsafe_ledger_is_not_executed_or_read_as_shell(self):
        self.assertEqual(self.run_cli("install","--yes").returncode,0)
        ledger=self.ledger/"installed-packages"
        marker=self.root/"unexpected"
        ledger.write_text("$(touch "+str(marker)+")\n");ledger.chmod(0o600)
        result=self.run_cli("remove","--yes")
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(marker.exists())
        ledger.chmod(0o666)
        self.assertNotEqual(self.run_cli("owned").returncode,0)

    def test_finalizer_propagates_dependency_failure_without_initialization(self):
        marker=self.root/"initialized"
        command='source <(sed \'$d\' "$1"); MARKER="$2"; check_dependencies() { return 42; }; init_config() { /usr/bin/touch "$MARKER"; }; install_tc_recovery_service_files() { :; }; refresh_all_cron_from_config() { :; }; restore_runtime_state() { :; }; if finalize_script_update; then exit 99; fi; test ! -e "$MARKER"'
        result=subprocess.run(["/bin/bash","-c",command,"test",str(self.script),str(marker)],env=self.env,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertFalse(marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
