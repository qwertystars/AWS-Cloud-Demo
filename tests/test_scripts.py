"""Offline behavior checks; fake executables never contact AWS or run Terraform.

Every scenario runs against both entry points, so the PowerShell scripts used on
Windows are held to the behavior of the Bash scripts used on Linux and macOS.
Suites whose interpreter is unavailable are skipped rather than failed.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).stem
args = sys.argv[1:]
mode = os.environ.get('SCENARIO', '')
# CRLF reproduces the line endings the AWS CLI and Python print on Windows.
ending = '\r\n' if os.environ.get('CRLF') else '\n'
def emit(text): sys.stdout.write(text + ending)
with open(os.environ['CALLS'], 'a') as f:
    f.write(name + ' ' + ' '.join(args) + '\n')
if name == 'terraform':
    if args[0] == 'output':
        emit({'demo_url':'http://demo.invalid', 'account_id':'123456789012',
              'region':'ap-south-1'}.get(args[-1], 'demo'))
    elif args[0] == 'workspace': emit('default')
    elif args[0] == 'console':
        sys.stdin.read()
        emit('"ap-south-1"')
    elif args[:2] == ['state', 'list']: emit('aws_lb.demo')
    elif args[:2] == ['state', 'pull']:
        emit(json.dumps({'resources': ([{'mode':'managed','type':'aws_lb','name':'demo',
             'instances':[{'attributes':{'arn':'arn:aws:elasticloadbalancing:ap-south-1:123456789012:loadbalancer/app/demo'}}]}]
             if mode == 'remaining' else [])}))
elif name == 'aws':
    stopped = pathlib.Path(os.environ['COUNTER'] + '.stopped')
    if args[0] == 'sts':
        emit('999999999999' if mode == 'wrong-account' else '123456789012')
    elif args[1] == 'wait': pass
    elif args[1] == 'describe-services': emit('2\t2\t0')
    elif args[1] == 'describe-target-health':
        emit('1' if mode == 'unhealthy' else '2')
    elif args[1] == 'list-tasks':
        emit(('replacement' if stopped.exists() else 'victim') + '\tsurvivor')
    elif args[1] == 'stop-task':
        stopped.write_text('stopped')
        emit('STOPPING')
elif name == 'curl':
    if mode == 'http-error': sys.exit(22)
    counter = pathlib.Path(os.environ['COUNTER'])
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n+1))
    emit('<h2>Served by: backend-%d</h2>' % (1 if mode == 'one' else n % 2 + 1))
'''

# Windows resolves executables through PATHEXT, so each fake gets a shim too.
SHIM = '@echo off\r\n"{python}" "%~dp0{name}" %*\r\n'

# The wrapper neutralizes waiting so a 60-attempt readiness loop stays quick,
# and forwards the script's exit code, which `pwsh -Command` does not preserve.
WRAPPER = '''function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) }
$target = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
& $target @rest
exit $LASTEXITCODE
'''

BASH = shutil.which('bash')
POWERSHELL = shutil.which('pwsh') or shutil.which('powershell')
SHELL_SCRIPTS = ('setup.sh', 'status.sh', 'demo.sh', 'failover-demo.sh', 'destroy.sh',
                 'scripts/common.sh', 'local/demo.sh')
POWERSHELL_SCRIPTS = ('setup.ps1', 'status.ps1', 'demo.ps1', 'failover-demo.ps1', 'destroy.ps1',
                      'scripts/common.ps1', 'local/demo.ps1')


class Behavior:
    """Scenarios shared by both implementations; mixed into the suites below."""

    extension = ''

    def build_command(self, directory, script, args):
        raise NotImplementedError

    def run_script(self, script, scenario='', args=(), stdin='', crlf=False):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name in ('terraform', 'aws', 'curl', 'sleep'):
                executable = base / name
                executable.write_text(FAKE)
                executable.chmod(0o755)
                if os.name == 'nt':
                    (base / (name + '.cmd')).write_text(SHIM.format(python=sys.executable, name=name))
            env = dict(os.environ, PATH=str(base) + os.pathsep + os.environ['PATH'],
                       SCENARIO=scenario, CALLS=str(base / 'calls'), COUNTER=str(base / 'count'),
                       CRLF='1' if crlf else '')
            command = self.build_command(base, ROOT / (script + self.extension), args)
            result = subprocess.run(command, input=stdin, text=True, capture_output=True, env=env)
            calls = base / 'calls'
            return result, calls.read_text() if calls.exists() else ''

    def test_balancing(self):
        result, _ = self.run_script('demo')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Unique backends observed: 2', result.stdout)
        self.assertEqual(result.stdout.count('Request '), 20)

    def test_one_backend_warns(self):
        result, _ = self.run_script('demo', 'one')
        self.assertEqual(result.returncode, 0)
        self.assertIn('WARNING', result.stderr)

    def test_http_failure_exits(self):
        result, _ = self.run_script('demo', 'http-error')
        self.assertNotEqual(result.returncode, 0)

    def test_setup_cancelled(self):
        result, calls = self.run_script('setup', stdin='no\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Cancelled', result.stdout)
        self.assertNotIn('terraform apply', calls)

    def test_setup_applies_the_approved_plan(self):
        result, calls = self.run_script('setup', stdin='apply\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        plans = [line for line in calls.splitlines() if line.startswith('terraform plan ')]
        applies = [line for line in calls.splitlines() if line.startswith('terraform apply ')]
        self.assertEqual(len(applies), 1)
        # Terraform must apply the saved plan that was shown and approved.
        self.assertTrue(plans[0].endswith('-out=' + applies[0].split()[-1]), plans[0])
        self.assertIn('DEMO READY', result.stdout)

    def test_setup_leaves_no_plan_file_behind(self):
        for stdin in ('no\n', 'apply\n'):
            with self.subTest(stdin=stdin):
                self.run_script('setup', stdin=stdin)
                self.assertEqual(sorted(ROOT.glob('aws-class-demo-plan-*')), [])

    def test_destroy_cancelled(self):
        result, calls = self.run_script('destroy', stdin='no\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('terraform destroy', calls)

    def test_wrong_account_refused(self):
        result, calls = self.run_script('destroy', 'wrong-account', ('--yes',))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('terraform destroy', calls)

    def test_failover_stops_exactly_one(self):
        result, calls = self.run_script('failover-demo', args=('--yes',))
        self.assertEqual(result.returncode, 0, result.stderr)
        stops = [line for line in calls.splitlines() if 'aws ecs stop-task' in line]
        self.assertEqual(len(stops), 1)
        self.assertIn('--cluster demo --task victim', stops[0])
        self.assertIn('Replacement task: replacement', result.stdout)

    def test_failover_cancelled(self):
        result, calls = self.run_script('failover-demo', stdin='no\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('aws ecs stop-task', calls)

    def test_unhealthy_service_not_stopped(self):
        result, calls = self.run_script('failover-demo', 'unhealthy', ('--yes',))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Readiness timed out', result.stderr)
        self.assertNotIn('aws ecs stop-task', calls)

    def test_cleanup_verified(self):
        result, calls = self.run_script('destroy', args=('--yes',))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('terraform destroy', calls)
        self.assertIn('Cleanup successful', result.stdout)

    def test_remaining_resources_fail(self):
        result, _ = self.run_script('destroy', 'remaining', ('--yes',))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('managed resources remain', result.stderr)

    def test_unexpected_argument_rejected(self):
        result, _ = self.run_script('status', args=('extra',))
        self.assertEqual(result.returncode, 2)

    def test_balancing_with_windows_line_endings(self):
        result, _ = self.run_script('demo', crlf=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Unique backends observed: 2', result.stdout)
        self.assertIn('backend-1', result.stdout)

    def test_failover_with_windows_line_endings(self):
        # Readiness compares counts as text, so a stray CR must never reach one.
        result, calls = self.run_script('failover-demo', args=('--yes',), crlf=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--cluster demo --task victim', calls)
        self.assertIn('Replacement task: replacement', result.stdout)


@unittest.skipUnless(BASH, 'bash is not installed')
class BashScripts(Behavior, unittest.TestCase):
    extension = '.sh'

    def build_command(self, directory, script, args):
        return [BASH, str(script), *args]

    def test_syntax(self):
        for script in SHELL_SCRIPTS:
            with self.subTest(script=script):
                result = subprocess.run([BASH, '-n', str(ROOT / script)], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)


@unittest.skipUnless(POWERSHELL, 'PowerShell is not installed')
class PowerShellScripts(Behavior, unittest.TestCase):
    extension = '.ps1'

    def build_command(self, directory, script, args):
        wrapper = Path(directory) / 'run-script.ps1'
        wrapper.write_text(WRAPPER)
        return [POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(wrapper), str(script), *args]

    def test_syntax(self):
        # -Command joins any trailing arguments into the command string, so the
        # checker is a script file that receives the paths as real arguments.
        check = ('$failed = $false\n'
                 'foreach ($file in $args) {\n'
                 '  $errors = $null\n'
                 '  [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$errors)\n'
                 '  if ($errors) { $failed = $true; [Console]::Error.WriteLine("${file}: $($errors[0].Message)") }\n'
                 '}\n'
                 'if ($failed) { exit 1 }\n')
        with tempfile.TemporaryDirectory() as directory:
            checker = Path(directory) / 'check-syntax.ps1'
            checker.write_text(check)
            result = subprocess.run(
                [POWERSHELL, '-NoLogo', '-NoProfile', '-File', str(checker),
                 *[str(ROOT / script) for script in POWERSHELL_SCRIPTS]],
                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
