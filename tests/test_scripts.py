"""Offline behavior checks; fake executables never contact AWS or run Terraform."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get('SCENARIO', '')
with open(os.environ['CALLS'], 'a') as f:
    f.write(name + ' ' + ' '.join(args) + '\n')
if name == 'terraform':
    if args[0] == 'output':
        print({'demo_url':'http://demo.invalid', 'account_id':'123456789012',
               'region':'ap-south-1'}.get(args[-1], 'demo'))
    elif args[0] == 'workspace': print('default')
    elif args[0] == 'console': print('"ap-south-1"')
    elif args[:2] == ['state', 'list']: print('aws_lb.demo')
    elif args[:2] == ['state', 'pull']:
        print(json.dumps({'resources': ([{'mode':'managed','type':'aws_lb','name':'demo',
             'instances':[{'attributes':{'arn':'arn:aws:elasticloadbalancing:ap-south-1:123456789012:loadbalancer/app/demo'}}]}]
             if mode == 'remaining' else [])}))
elif name == 'aws':
    stopped = pathlib.Path(os.environ['COUNTER'] + '.stopped')
    if args[0] == 'sts':
        print('999999999999' if mode == 'wrong-account' else '123456789012')
    elif args[1] == 'wait': pass
    elif args[1] == 'describe-services': print('2\t2\t0')
    elif args[1] == 'describe-target-health':
        print('1' if mode == 'unhealthy' else '2')
    elif args[1] == 'list-tasks':
        print(('replacement' if stopped.exists() else 'victim') + '\tsurvivor')
    elif args[1] == 'stop-task':
        stopped.write_text('stopped')
        print('STOPPING')
elif name == 'curl':
    if mode == 'http-error': sys.exit(22)
    counter = pathlib.Path(os.environ['COUNTER'])
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n+1))
    print('<h2>Served by: backend-%d</h2>' % (1 if mode == 'one' else n % 2 + 1))
'''

class Scripts(unittest.TestCase):
    def run_script(self, script, scenario='', args=(), stdin=''):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name in ('terraform', 'aws', 'curl', 'sleep'):
                executable = base / name
                executable.write_text(FAKE)
                executable.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'],
                       SCENARIO=scenario, CALLS=str(base/'calls'), COUNTER=str(base/'count'))
            result = subprocess.run(['bash', str(ROOT/script), *args], input=stdin,
                                    text=True, capture_output=True, env=env)
            return result, (base/'calls').read_text()

    def test_balancing(self):
        result, _ = self.run_script('demo.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Unique backends observed: 2', result.stdout)
        self.assertEqual(result.stdout.count('Request '), 20)

    def test_one_backend_warns(self):
        result, _ = self.run_script('demo.sh', 'one')
        self.assertEqual(result.returncode, 0)
        self.assertIn('WARNING', result.stderr)

    def test_http_failure_exits(self):
        result, _ = self.run_script('demo.sh', 'http-error')
        self.assertNotEqual(result.returncode, 0)

    def test_destroy_cancelled(self):
        result, calls = self.run_script('destroy.sh', stdin='no\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('terraform destroy', calls)

    def test_wrong_account_refused(self):
        result, calls = self.run_script('destroy.sh', 'wrong-account', ('--yes',))
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('terraform destroy', calls)

    def test_failover_stops_exactly_one(self):
        result, calls = self.run_script('failover-demo.sh', args=('--yes',))
        self.assertEqual(result.returncode, 0, result.stderr)
        stops = [line for line in calls.splitlines() if 'aws ecs stop-task' in line]
        self.assertEqual(len(stops), 1)
        self.assertIn('--cluster demo --task victim', stops[0])
        self.assertIn('Replacement task: replacement', result.stdout)

    def test_failover_cancelled(self):
        result, calls = self.run_script('failover-demo.sh', stdin='no\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('aws ecs stop-task', calls)

    def test_unhealthy_service_not_stopped(self):
        result, calls = self.run_script('failover-demo.sh', 'unhealthy', ('--yes',))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Readiness timed out', result.stderr)
        self.assertNotIn('aws ecs stop-task', calls)

    def test_cleanup_verified(self):
        result, calls = self.run_script('destroy.sh', args=('--yes',))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('terraform destroy', calls)
        self.assertIn('Cleanup successful', result.stdout)

    def test_remaining_resources_fail(self):
        result, _ = self.run_script('destroy.sh', 'remaining', ('--yes',))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('managed resources remain', result.stderr)

if __name__ == '__main__':
    unittest.main()
