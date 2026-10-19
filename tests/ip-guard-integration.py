#!/usr/bin/env python3
"""Real Linux TCP/NFQUEUE acceptance. Run ONLY inside a disposable namespace harness."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import select
import selectors
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

SERVER4, SERVER6 = '198.18.71.1', 'fd42:6e74:6319::1'
SOURCES4 = ['198.18.71.%d' % i for i in range(2, 8)]
SOURCES6 = ['fd42:6e74:6319::%x' % i for i in range(2, 8)]


def client():
    streams = {}
    for line in sys.stdin:
        request = json.loads(line)
        name, operation = request.get('name'), request['op']
        try:
            if operation == 'connect':
                family = socket.AF_INET6 if ':' in request['source'] else socket.AF_INET
                stream = socket.socket(family)
                stream.settimeout(0.8)
                stream.bind((request['source'], 0))
                try:
                    stream.connect((SERVER6 if family == socket.AF_INET6 else SERVER4, request['port']))
                except Exception:
                    stream.close()
                    raise
                streams[name] = stream
            elif operation == 'parallel':
                barrier = threading.Barrier(request['count'])
                accepted = []
                def attempt(index):
                    stream = socket.socket(socket.AF_INET)
                    stream.settimeout(0.8)
                    stream.bind((request['source'], 0))
                    barrier.wait(timeout=2)
                    try:
                        stream.connect((SERVER4, request['port']))
                        stream.sendall(b'guard-real-echo')
                        assert stream.recv(100) == b'guard-real-echo'
                        streams['parallel%d' % index] = stream
                        accepted.append(index)
                    except (OSError, AssertionError):
                        stream.close()
                workers = [threading.Thread(target=attempt, args=(index,)) for index in range(request['count'])]
                for worker in workers: worker.start()
                for worker in workers: worker.join(2)
                assert all(not worker.is_alive() for worker in workers)
                print(json.dumps({'ok': True, 'accepted': len(accepted)}), flush=True)
                continue
            elif operation == 'close':
                stream = streams.pop(name)
                stream.shutdown(socket.SHUT_WR)
                while stream.recv(1024):
                    pass
                stream.close()
            elif operation == 'echo':
                stream = streams[name]
                stream.sendall(b'guard-real-echo')
                assert stream.recv(100) == b'guard-real-echo'
            elif operation == 'quit':
                break
            print(json.dumps({'ok': True}), flush=True)
        except Exception as error:
            print(json.dumps({'ok': False, 'error': type(error).__name__}), flush=True)
    for stream in streams.values():
        stream.close()


class Server:
    def __init__(self, port):
        self.selector = selectors.DefaultSelector()
        self.stopping = threading.Event()
        for family, address in [(socket.AF_INET, SERVER4), (socket.AF_INET6, SERVER6)]:
            stream = socket.socket(family)
            stream.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if family == socket.AF_INET6:
                stream.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            stream.bind((address, port))
            stream.listen(64)
            stream.setblocking(False)
            self.selector.register(stream, selectors.EVENT_READ, True)
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        while not self.stopping.is_set():
            for key, _ in self.selector.select(0.05):
                stream = key.fileobj
                if key.data:
                    connection, _ = stream.accept()
                    self.selector.register(connection, selectors.EVENT_READ, False)
                else:
                    try:
                        data = stream.recv(2048)
                        if data:
                            stream.sendall(data)
                            continue
                    except (ConnectionError, OSError):
                        pass
                    self.selector.unregister(stream)
                    stream.close()

    def close(self):
        self.stopping.set()
        self.thread.join(1)
        assert not self.thread.is_alive()
        for key in list(self.selector.get_map().values()):
            key.fileobj.close()
        self.selector.close()


def command(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=8, **kwargs)


def wait_for(condition, message, timeout=8):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        if condition():
            return
        time.sleep(0.1)
    raise AssertionError(message)


class Suite:
    def __init__(self):
        self.work = Path(tempfile.mkdtemp(prefix='ip-guard-limits-'))
        self.script = Path(__file__).resolve().parents[1] / 'port-ip-guard.sh'
        self.digest = hashlib.sha256(self.script.read_bytes()).hexdigest()
        self.namespace = 'iglc%d' % os.getpid()
        self.interface = 'igl%d' % os.getpid()
        self.peer = 'igp%d' % os.getpid()
        self.table = 'ip_guard_limits_%d' % os.getpid()
        self.guard, self.worker, self.server, self.client = None, None, None, None
        self.port = 43870
        self.passed = 0
        self.audit_events = set()
        self.log = None
        command('ip', 'netns', 'add', self.namespace)
        command('ip', 'link', 'add', self.interface, 'type', 'veth', 'peer', 'name', self.peer)
        command('ip', 'link', 'set', self.peer, 'netns', self.namespace)
        command('ip', 'addr', 'add', SERVER4 + '/24', 'dev', self.interface)
        command('ip', '-6', 'addr', 'add', SERVER6 + '/64', 'dev', self.interface, 'nodad')
        command('ip', 'link', 'set', self.interface, 'up')
        command('ip', '-n', self.namespace, 'link', 'set', 'lo', 'up')
        for source in SOURCES4:
            command('ip', '-n', self.namespace, 'addr', 'add', source + '/24', 'dev', self.peer)
        for source in SOURCES6:
            command('ip', '-n', self.namespace, '-6', 'addr', 'add', source + '/64', 'dev', self.peer, 'nodad')
        command('ip', '-n', self.namespace, 'link', 'set', self.peer, 'up')

    def ok(self, message):
        self.passed += 1
        print('PASS ' + message, flush=True)

    def request(self, operation, name='', **fields):
        self.client.stdin.write(json.dumps(dict(op=operation, name=name, **fields)) + '\n')
        self.client.stdin.flush()
        assert select.select([self.client.stdout], [], [], 3)[0], 'client request timed out'
        line = self.client.stdout.readline()
        assert line, 'client exited'
        return json.loads(line)

    def connect(self, name, source, accepted=True):
        result = self.request('connect', name, source=source, port=self.port)
        assert result['ok'] == accepted, (name, source, accepted, result)
        if accepted:
            assert self.request('echo', name)['ok']
        else:
            assert result['error'] == 'TimeoutError', result

    def state(self):
        try:
            return json.loads((self.config / 'ip-guard-state.json').read_text())['ports'][str(self.port)]
        except (OSError, ValueError, KeyError):
            return {}

    def begin(self, ips, connections, preexisting=()):
        self.end()
        self.port += 1
        self.config = self.work / str(self.port)
        self.config.mkdir()
        (self.config / 'ip-guard.json').write_text(json.dumps({
            'schema': 'port-traffic-dog-ip-guard-v1',
            'ports': {str(self.port): {'max_ips': ips, 'max_connections': connections, 'idle_timeout': 2}}}))
        self.server = Server(self.port)
        self.client = subprocess.Popen(['ip', 'netns', 'exec', self.namespace, sys.executable, '-u', __file__, '--client'],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        for name, source in preexisting:
            self.connect(name, source)
        environment = {key: value for key, value in os.environ.items() if not key.startswith('PTD_IP_GUARD_')}
        environment.update(PTD_IP_GUARD_CONFIG_DIR=str(self.config),
                           PTD_IP_GUARD_LOCK_FILE=str(self.config / 'guard.lock'),
                           PTD_IP_GUARD_TABLE_NAME=self.table,
                           PTD_IP_GUARD_RECONCILE_SECONDS='1')
        self.log = (self.config / 'guard.log').open('w')
        self.guard = subprocess.Popen(['bash', str(self.script), '--run'], env=environment,
                                      stdout=self.log, stderr=subprocess.STDOUT)
        if not ips and not connections:
            assert self.guard.wait(5) == 0
            return
        def ready():
            assert self.guard.poll() is None, (self.config / 'guard.log').read_text()
            result = subprocess.run(['nft', '-j', 'list', 'table', 'inet', self.table], capture_output=True, text=True)
            return result.returncode == 0
        wait_for(ready, 'guard never installed rules')
        self.worker = json.loads((self.config / 'ip-guard-state.json').read_text())['pid']
        # The real JSON contract, not only a generated string, must self-validate.
        table = command('nft', '-j', 'list', 'table', 'inet', self.table).stdout
        contract = 'source "$1"; nft_port_contract_valid "$2" "$3"'
        command('bash', '-c', contract, 'contract', str(self.script), table, str(self.port))
        selfcheck = 'source "$1"; service_file_is_owned() { :; }; SYSTEMCTL=/bin/true; self_check'
        command('bash', '-c', selfcheck, 'selfcheck', str(self.script), env=environment)
        if preexisting:
            assert self.state().get('connections') == len(preexisting), ('preexisting dual-stack snapshot', self.state())

    def end(self):
        if self.guard:
            if self.guard.poll() is None:
                self.guard.terminate()
                self.guard.wait(8)
                assert self.guard.returncode == 0
            if self.log:
                self.log.close()
            print('GUARD_LOG ' + str(self.port) + '\n' + (self.config / 'guard.log').read_text(), flush=True)
            self.guard = None
        if self.log:
            audit_path = self.config / 'logs' / 'ip-guard.log'
            if audit_path.exists():
                text = audit_path.read_text()
                assert all(source not in text for source in SOURCES4 + SOURCES6), 'raw source address in audit'
                events = [json.loads(line) for line in text.splitlines()]
                self.audit_events.update(entry['event'] for entry in events)
                assert all('message' in entry for entry in events)
                assert audit_path.stat().st_mode & 0o777 == 0o600
        if self.worker:
            wait_for(lambda: subprocess.run(['bash', '-c', 'kill -0 "$1" 2>/dev/null', 'check', str(self.worker)]).returncode != 0,
                     'worker survived supervisor', 5)
            self.worker = None
        subprocess.run(['nft', 'delete', 'table', 'inet', self.table], capture_output=True)
        if self.client:
            self.client.stdin.close()
            self.client.wait(3)
            self.client = None
        if self.server:
            self.server.close()
            self.server = None

    def orphan_reaped(self):
        try:
            child, status = os.waitpid(self.worker, os.WNOHANG)
            if child == self.worker:
                print('ORPHAN_REAPED pid=%d status=%d' % (child, status), flush=True)
                return True
        except ChildProcessError:
            return not Path('/proc/%d' % self.worker).exists()
        return False

    def run(self):
        self.begin(2, 0)
        self.connect('first', SOURCES4[0])
        self.connect('same-ip', SOURCES4[0])
        self.connect('second-family', SOURCES6[0])
        collision = self.work / 'queue-collision'
        collision.mkdir()
        (collision / 'ip-guard.json').write_bytes((self.config / 'ip-guard.json').read_bytes())
        collision_env = dict(os.environ, PTD_IP_GUARD_CONFIG_DIR=str(collision),
                             PTD_IP_GUARD_LOCK_FILE=str(collision / 'guard.lock'),
                             PTD_IP_GUARD_TABLE_NAME=self.table + '_collision', PTD_IP_GUARD_RECONCILE_SECONDS='1')
        result = subprocess.run(['bash', str(self.script), '--run'], env=collision_env, capture_output=True, text=True, timeout=8)
        assert result.returncode != 0 and 'already owned' in result.stdout + result.stderr
        assert self.guard.poll() is None and self.request('echo', 'first')['ok']
        assert subprocess.run(['nft', 'list', 'table', 'inet', self.table + '_collision'], capture_output=True).returncode != 0
        self.ok('foreign queue collision rejected without stealing consumer or installing rules')
        self.connect('over-ip4', SOURCES4[1], False)
        self.connect('over-ip6', SOURCES6[1], False)
        assert self.request('echo', 'first')['ok'] and self.request('echo', 'second-family')['ok']
        self.ok('first-ever SYN, same-IP dedup, IPv4/IPv6 shared IP cap, active sockets preserved')
        for name in ['first', 'same-ip']:
            assert self.request('close', name)['ok']
        wait_for(lambda: self.state().get('online_ips') == 1, 'closed IP did not release active slot')
        residual = command('conntrack', '-L', '-p', 'tcp', '-o', 'extended').stdout
        assert 'TIME_WAIT' in residual or 'CLOSE' in residual
        self.connect('replacement', SOURCES4[1])
        self.ok('new source admitted after graceful close despite TIME_WAIT residual; no events required')
        self.guard.terminate()
        assert self.guard.wait(5) == 0
        self.connect('term-open', SOURCES6[1])
        assert self.request('echo', 'second-family')['ok']
        self.ok('TERM fail-open and preserved active traffic')

        self.begin(0, 2)
        self.connect('c1', SOURCES4[0])
        self.connect('c2', SOURCES4[0])
        self.connect('c3', SOURCES4[0], False)
        self.connect('other-family', SOURCES6[0], False)
        assert self.request('close', 'c1')['ok']
        wait_for(lambda: self.state().get('connections') == 1, 'connection slot did not release')
        self.connect('new6', SOURCES6[0])
        self.ok('connection cap counts same-IP flows separately, aggregates families and releases slot')

        self.begin(1, 2)
        self.connect('both1', SOURCES4[0])
        self.connect('both2', SOURCES4[0])
        self.connect('both3', SOURCES4[0], False)
        assert self.request('close', 'both1')['ok']
        wait_for(lambda: self.state().get('connections') == 1, 'combined slot did not release')
        self.connect('different-ip', SOURCES6[0], False)
        self.connect('same-allowed', SOURCES4[0])
        self.ok('combined limits enforce each independently')
        os.kill(self.worker, signal.SIGKILL)
        assert self.guard.wait(5) != 0
        self.connect('worker-crash-open', SOURCES6[0])
        self.ok('consumer SIGKILL causes supervisor cleanup and fail-open')

        self.begin(1, 1, [('old4', SOURCES4[0]), ('old6', SOURCES6[0])])
        assert self.request('echo', 'old4')['ok'] and self.request('echo', 'old6')['ok']
        self.connect('new-over-existing', SOURCES4[0], False)
        self.ok('startup imports existing connections above both caps without disconnecting them')
        os.kill(self.guard.pid, signal.SIGKILL)
        self.guard.wait(3)
        wait_for(self.orphan_reaped, 'orphan worker did not exit/reap', 5)
        self.connect('supervisor-crash-open', SOURCES4[1])
        self.ok('supervisor SIGKILL releases consumer; nft bypass permits new clients')

        self.begin(0, 3)
        result = self.request('parallel', source=SOURCES4[0], port=self.port, count=8)
        assert result.get('ok') and result['accepted'] == 3, result
        wait_for(lambda: self.state().get('connections') == 3, 'parallel admissions not counted')
        self.ok('eight simultaneous handshakes admit exactly three under connection cap')

        self.begin(0, 0)
        for index, source in enumerate([SOURCES4[0], SOURCES4[1], SOURCES6[0]]):
            self.connect('unlimited%d' % index, source)
        self.ok('both zero: no consumer/rules and unrestricted TCP')
        assert hashlib.sha256(self.script.read_bytes()).hexdigest() == self.digest
        self.ok('source bytes unchanged SHA256=' + self.digest)
        self.end()
        assert {'admit', 'reject', 'release', 'startup', 'shutdown', 'fail_open'} <= self.audit_events, self.audit_events
        self.ok('real admission, rejection, release and fail-open produce private Chinese audit records')

    def cleanup(self):
        self.end()
        subprocess.run(['ip', 'link', 'del', self.interface], capture_output=True)
        subprocess.run(['ip', 'netns', 'del', self.namespace], capture_output=True)
        assert not any(item['name'] == self.namespace for item in json.loads(command('ip', '-j', 'netns').stdout))
        self.ok('owned process, queue, veth and namespace cleanup')


def main():
    if '--client' in sys.argv:
        return client()
    assert os.environ.get('PI_NTC_DOG_ISOLATED') == '1', 'requires disposable mount/net/pid namespace harness'
    # Reap the worker adopted after intentionally killing its shell supervisor.
    assert ctypes.CDLL(None).prctl(36, 1, 0, 0, 0) == 0, 'cannot enable fixture child subreaper'
    suite = Suite()
    try:
        suite.run()
    finally:
        suite.cleanup()
    print('TOTAL %d passed, 0 failed' % suite.passed, flush=True)

if __name__ == '__main__':
    main()
