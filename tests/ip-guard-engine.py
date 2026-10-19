#!/usr/bin/env python3
"""Exercise the shipped admission engine without privileges or third-party Python modules."""
from pathlib import Path
import socket
import struct
import contextlib
import io
import json
import tempfile
import unittest

script = Path(__file__).resolve().parents[1] / 'port-ip-guard.sh'
code = script.read_text().split("<<'PTD_IP_GUARD_PY'\n", 1)[1].split('\nPTD_IP_GUARD_PY', 1)[0]
engine = {'__name__': 'guard_test'}
exec(compile(code, str(script) + ':embedded-python', 'exec'), engine)
Admission = engine['Admission']


def key(source='192.0.2.2', sport=40000, port=443):
    return (port, source, '192.0.2.1', sport)


class Limits(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0

    def model(self, ips=1, connections=0, idle=300):
        return Admission({'443': {'max_ips': ips, 'max_connections': connections, 'idle_timeout': idle}}, lambda: self.now)

    def test_first_syn_and_retransmissions(self):
        model = self.model(connections=1)
        self.assertTrue(model.admit(key()))
        self.assertTrue(model.admit(key()))
        self.assertEqual(model.status()['443']['connections'], 1)
        self.assertFalse(model.admit(key(sport=40001)))

    def test_same_source_is_one_ip_multiple_connections(self):
        model = self.model()
        self.assertTrue(model.admit(key()))
        self.assertTrue(model.admit(key(sport=40001)))
        self.assertEqual(model.status()['443']['online_ips'], 1)
        self.assertEqual(model.status()['443']['connections'], 2)
        self.assertFalse(model.admit(key('2001:db8::2')))

    def test_connection_only_cap(self):
        model = self.model(ips=0, connections=2)
        self.assertTrue(model.admit(key()))
        self.assertTrue(model.admit(key('2001:db8::2')))
        self.assertFalse(model.admit(key(sport=40001)))

    def test_both_unlimited(self):
        model = self.model(ips=0, connections=0)
        for index in range(20):
            self.assertTrue(model.admit(key('192.0.2.%d' % (index + 2), 40000 + index)))
        self.assertEqual(model.status()['443']['connections'], 20)

    def test_pending_reservation_survives_confirmation_window(self):
        model = self.model()
        model.admit(key())
        model.reconcile([])
        self.assertFalse(model.admit(key('192.0.2.3')))
        self.now += 29
        self.assertTrue(model.admit(key()))
        self.now += 2
        model.reconcile([])
        self.assertTrue(model.admit(key('192.0.2.3')))

    def test_closed_flow_releases_both_slots_and_retains_idle_preference(self):
        model = self.model(connections=1)
        model.admit(key())
        model.reconcile([(key(), 'ESTABLISHED')])
        model.reconcile([(key(), 'TIME_WAIT')])
        self.assertEqual(model.status()['443']['connections'], 0)
        self.assertEqual(model.status()['443']['idle_ips'], 1)
        self.assertTrue(model.admit(key('192.0.2.3')))
        self.assertEqual(model.status()['443']['idle_ips'], 0)

    def test_time_wait_does_not_extend_idle_retention(self):
        model = self.model()
        model.reconcile([(key(), 'ESTABLISHED')])
        model.reconcile([(key(), 'TIME_WAIT')])
        self.now += 200
        model.reconcile([(key(), 'TIME_WAIT')])
        self.now += 101
        model.reconcile([(key(), 'CLOSE')])
        self.assertEqual(model.status()['443']['idle_ips'], 0)

    def test_existing_active_connections_above_cap_are_preserved(self):
        model = self.model(connections=1)
        old = [key(), key('2001:db8::2')]
        model.reconcile([(item, 'ESTABLISHED') for item in old])
        for item in old:
            self.assertTrue(model.admit(item))
        self.assertFalse(model.admit(key(sport=40001)))
        self.assertEqual(model.status()['443']['connections'], 2)

    def test_confirmed_disappearance_releases_connection(self):
        model = self.model(connections=1)
        model.admit(key())
        model.reconcile([(key(), 'ESTABLISHED')])
        model.reconcile([])
        self.assertTrue(model.admit(key(sport=40001)))

    def test_ports_independent(self):
        model = Admission({'443': {'max_ips': 1, 'max_connections': 1}, '8443': {'max_ips': 1, 'max_connections': 1}})
        self.assertTrue(model.admit(key()))
        self.assertTrue(model.admit(key('2001:db8::2', port=8443)))
        self.assertFalse(model.admit(key(sport=40001)))

    def test_snapshot_uses_reply_service_port(self):
        text = 'tcp 6 120 ESTABLISHED src=192.0.2.2 dst=192.0.2.1 sport=40000 dport=443 src=192.0.2.1 dst=192.0.2.2 sport=8443 dport=40000'
        records = engine['conntrack_records'](text, {'192.0.2.1'})
        self.assertEqual(records[0][0][0], 8443)
        outgoing = text.replace('src=192.0.2.2 dst=192.0.2.1', 'src=192.0.2.1 dst=192.0.2.2').replace('src=192.0.2.1 dst=192.0.2.2 sport=8443', 'src=192.0.2.2 dst=192.0.2.1 sport=8443')
        self.assertEqual(engine['conntrack_records'](outgoing, {'192.0.2.1'}), [])

    def test_packet_parser_ipv4_ipv6_and_extension(self):
        tcp = struct.pack('!HHIIBBHHH', 40000, 443, 0, 0, 80, 2, 65535, 0, 0)
        ipv4 = struct.pack('!BBHHHBBH4s4s', 69, 0, 40, 0, 0, 64, 6, 0, socket.inet_pton(socket.AF_INET, '192.0.2.2'), socket.inet_pton(socket.AF_INET, '192.0.2.1'))
        self.assertEqual(engine['syn_key'](ipv4 + tcp), key())
        ipv6 = struct.pack('!IHBB16s16s', 6 << 28, 28, 0, 64, socket.inet_pton(socket.AF_INET6, '2001:db8::2'), socket.inet_pton(socket.AF_INET6, '2001:db8::1'))
        parsed = engine['syn_key'](ipv6 + bytes([6, 0]) + bytes(6) + tcp)
        self.assertEqual(parsed, (443, '2001:db8::2', '2001:db8::1', 40000))
        self.assertIsNone(engine['syn_key'](b''))
        self.assertIsNone(engine['syn_key'](ipv4 + tcp[:5]))

    def test_socket_snapshot_covers_existing_dual_stack_and_mapped_ipv4(self):
        text = '\n'.join([
            'ESTAB 0 0 192.0.2.1:443 192.0.2.2:40000',
            'ESTAB 0 0 [2001:db8::1]:443 [2001:db8::2]:40001',
            'ESTAB 0 0 [::ffff:192.0.2.1]:443 [::ffff:192.0.2.3]:40002',
            'TIME-WAIT 0 0 192.0.2.1:443 192.0.2.4:40003',
        ])
        records = engine['socket_records'](text)
        self.assertEqual(len(records), 3)
        self.assertEqual(records[0][0], key())
        self.assertEqual(records[2][0], key('192.0.2.3', 40002))

    def test_audit_is_private_bounded_chinese_and_rate_limited(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'logs' / 'ip-guard.log'
            audit = engine['Audit'](str(path))
            for _ in range(100):
                audit.limited('reject', 443, source='192.0.2.2', reason='connection_limit')
            audit.flush(force=True)
            text = path.read_text()
            self.assertNotIn('192.0.2.2', text)
            self.assertIn('并发连接数达到上限', text)
            entries = [json.loads(line) for line in text.splitlines()]
            self.assertEqual(len(entries), 2)
            self.assertEqual(entries[1]['count'], 99)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            with path.open('ab') as output:
                output.write(b'x' * 1048576)
            audit.emit('shutdown', result=0, token='DO_NOT_LOG')
            self.assertTrue(Path(str(path) + '.1').exists())
            self.assertLess(path.stat().st_size, 4096)
            self.assertNotIn('DO_NOT_LOG', path.read_text())

    def test_audit_failure_does_not_change_admission(self):
        with tempfile.TemporaryDirectory() as directory:
            blocker = Path(directory) / 'file'
            blocker.write_text('not a directory')
            audit = engine['Audit'](str(blocker / 'ip-guard.log'))
            model = Admission({'443': {'max_ips': 1}}, audit=audit)
            errors = io.StringIO()
            with contextlib.redirect_stderr(errors):
                self.assertTrue(model.admit(key()))
                self.assertFalse(model.admit(key('192.0.2.3')))
            self.assertIn('日志写入失败', errors.getvalue())


if __name__ == '__main__':
    unittest.main(verbosity=2)
