#!/usr/bin/env python3
"""Dog 主界面布局（2.1）：在伪终端里运行真实的循环菜单与仪表盘（只替换读取 nft/cron 的函数），检查：
- 主菜单两列即两组：左列 1..9、右列 10..17 竖排，右列起始列一致；放不下时单列并保留分组标题；
- 100/80/60/40 列下整屏每行显示宽度不超过终端宽度；
- 监控项表格含中文备注时各列起始显示位置一致（宽屏/紧凑），更窄时每项两行；
- NO_COLOR / TERM=dumb / 输出重定向时没有 ANSI；EOF 退出码为 0；
- 通知管理 → 选择推送的监控项：输入序号切换后配置写入，页头显示推送范围；
- 修改端口子菜单使用统一样式（请选择 [0-5]）；
- 菜单动作出错只结束该动作并回到菜单，动作内部仍是 set -e；取消卸载回到菜单，确认卸载后退出；
- stdin 不是终端时，列数取 stderr 所连终端的宽度。"""
import errno
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import tempfile
import termios
import time
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
PRODUCT = ROOT / 'port-traffic-dog.sh'
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
PROMPTS = ('请选择 ['.encode(), '回车取消）: '.encode(), '回车返回）: '.encode())
MAIN_PROMPT = '请选择 [0-17]'

CONFIG = {
    'schema': 2,
    'global': {'billing_mode': 'double', 'next_monitor_id': 4, 'data_retention_days': 400},
    'monitors': {
        'm1': {'ports': ['7023', '7031', '7032', '7082'], 'remark': '东京主线', 'billing_mode': 'double',
               'quota': {'enabled': True, 'monthly_limit': '300GB'},
               'reset_policy': {'type': 'monthly', 'day': 1, 'next_reset_date': '2099-12-01'}, 'expiry_date': '2099-12-31'},
        'm2': {'ports': ['9000-9010'], 'remark': '客户A', 'billing_mode': 'single',
               'quota': {'enabled': False, 'monthly_limit': 'unlimited'},
               'bandwidth_limit': {'enabled': True, 'rate': '100mbit'}, 'notify': False},
        'm3': {'ports': ['8443'], 'billing_mode': 'double',
               'quota': {'enabled': True, 'monthly_limit': '50GB'}, 'expiry_date': '2020-01-01'},
    },
    'notifications': {
        'telegram': {'enabled': True, 'bot_token': 'x', 'chat_id': '1', 'server_name': '', 'api_route': 'official',
                     'custom_api_base': '', 'status_notifications': {'enabled': True, 'interval': '12h'}},
        'wecom': {'enabled': False, 'webhook_url': '', 'server_name': '',
                  'status_notifications': {'enabled': False, 'interval': '1h'}},
    },
}
VALUES = {'m1': {'in': 1000000000, 'out': 8000000000}, 'm2': {'in': 200000000, 'out': 336870912},
          'm3': {'in': 13300000000, 'out': 14344245094}}
MACHINE = {'monthly': {'ifaces': {'eth0': {'rx_bytes': 1330000000000, 'tx_bytes': 1240000000000}}}}
USED = {'m1': '16.76GB', 'm2': '512.00MB', 'm3': '51.49GB'}
QUOTA = {'m1': '300GB', 'm2': '不限额', 'm3': '50GB'}
LABEL = {'m1': '东京主线', 'm2': '客户A', 'm3': '8443'}
FIRST_TAG = {'m2': '限速 100Mbps', 'm3': '超额'}
WRAPPER = '''#!/bin/bash
source <(sed '$d' "$1")
nft_read_values() { cat "$PTD_TEST_VALUES"; }
nft_table_exists() { return 0; }
nft_runtime_drift() { return 0; }
cron_in_sync() { return 0; }
hostname() { echo demo-node; }
pause() { :; }
#EXTRA#
show_main_menu
'''
DASHBOARD = ' · demo-node'


def write_wrapper(temp, name, extra=''):
    """测试包装脚本：source 产品后替换读取 nft/cron 的函数，extra 为追加的桩函数，最后进入主菜单。"""
    path = Path(temp) / f'wrapper-{name}.sh'
    path.write_text(WRAPPER.replace('#EXTRA#', extra))
    return path


def width(text):
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in text)


def new_state(temp, name):
    state = Path(temp) / name
    (state / 'logs').mkdir(parents=True)
    (state / 'config.json').write_text(json.dumps(CONFIG, ensure_ascii=False))
    (state / 'machine_traffic.json').write_text(json.dumps(MACHINE))
    (state / 'values.json').write_text(json.dumps(VALUES))
    env = dict(os.environ, PORT_TRAFFIC_DOG_CONFIG_DIR=str(state), PORT_TRAFFIC_DOG_LOCK_FILE=str(state / 'lock'),
               PTD_TEST_VALUES=str(state / 'values.json'))
    return state, env


def capture(columns, env, wrapper, answers, extra=None):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, columns, 0, 0))
    env = dict(env, TERM='xterm-256color', COLUMNS=str(columns))
    env.pop('NO_COLOR', None)
    env.update(extra or {})
    proc = subprocess.Popen(['/bin/bash', str(wrapper), str(PRODUCT)], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    data = b''
    sent = 0
    deadline = time.monotonic() + 40
    try:
        while time.monotonic() < deadline:
            if select.select([master], [], [], .1)[0]:
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno == errno.EIO:
                        break
                    raise
                if not chunk:
                    break
                data += chunk
                # 每出现一个新提示就回答一次。
                if sent < len(answers) and sum(data.count(p) for p in PROMPTS) > sent:
                    os.write(master, answers[sent])
                    sent += 1
            elif proc.poll() is not None:
                break
        result = proc.wait(timeout=max(.1, deadline - time.monotonic()))
        assert sent == len(answers) and result == 0, (sent, result, data.decode(errors='replace')[-1500:])
        return data.decode()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)


def plain(raw):
    return ANSI.sub('', raw).replace('\r', '')


def first_screen(text):
    lines = text.split('\n')
    end = next(i for i, line in enumerate(lines) if MAIN_PROMPT in line)
    return lines[:end + 1]


def check_main_menu(screen, label):
    start = next(i for i, line in enumerate(screen) if line.strip().startswith('监控项'))
    numbered = [[int(n) for n in re.findall(r'(\d+)\. ', line)] for line in screen[start:-1]]
    numbered = [nums for nums in numbered if nums]
    if '系统维护' in screen[start]:
        assert numbered == [[i, i + 9] for i in range(1, 9)] + [[9], [0]], (label, numbered)
        rows = [line for line in screen[start + 1:] if re.search(r'\d+\. .*\s(1\d)\. ', line)]
        starts = {width(line[:line.index(f'{n}. ', 8)]) for line in rows for n in [int(re.findall(r'(\d+)\. ', line)[1])]}
        header_start = width(screen[start][:screen[start].index('系统维护')])
        assert len(starts) == 1 and starts == {header_start}, (label, starts, header_start)
        return 'two-columns'
    assert numbered == [[i] for i in range(1, 18)] + [[0]], (label, numbered)
    assert any(line.strip() == '系统维护' for line in screen[start:]), (label, '缺少分组标题')
    return 'one-column'


def check_table(screen, label):
    header_index = next((i for i, line in enumerate(screen) if '端口 / 备注' in line), None)
    if header_index is None:
        for mid in LABEL:
            row = next((line for line in screen if re.match(rf'^\s+\d+\s+{mid}\s', line)), None)
            assert row and LABEL[mid] in row, (label, mid, screen)
        return 'card'
    header = screen[header_index]
    cols = {name: width(header[:header.index(name)]) for name in ('ID', '端口 / 备注', '周期流量', '配额', '状态')}
    for mid in LABEL:
        row = next(line for line in screen[header_index + 1:] if re.match(rf'^\s+\d+\s+{mid}\s', line))
        positions = {'ID': row.index(mid), '端口 / 备注': row.index(LABEL[mid], row.index(mid)),
                     '周期流量': row.index(USED[mid])}
        positions['配额'] = row.index(QUOTA[mid], positions['周期流量'] + len(USED[mid]))
        if mid in FIRST_TAG:
            positions['状态'] = row.index(FIRST_TAG[mid])
        for name, index in positions.items():
            assert width(row[:index]) == cols[name], (label, mid, name, width(row[:index]), cols[name], header, row)
    return 'wide' if '█' in '\n'.join(screen) else 'compact'


def main():
    labels = int(subprocess.run(
        ['/bin/bash', '-c', 'source <(sed \'$d\' "$1"); echo "${#MAIN_MENU_LABELS[@]}"', 'x', str(PRODUCT)],
        capture_output=True, text=True, timeout=10, env=dict(os.environ, NO_COLOR='1')).stdout.strip())
    assert labels == 17, labels
    with tempfile.TemporaryDirectory(prefix='dog-menu-test-') as temp:
        wrapper = write_wrapper(temp, 'base')
        cases = {}
        expected = {'wide': ('two-columns', 'wide'), 'medium': ('two-columns', 'compact'),
                    'narrow': ('one-column', 'card'), 'tiny': ('one-column', 'card'),
                    'no-color': ('two-columns', 'compact'), 'dumb': ('one-column', 'card')}
        for columns, extra, label in [(100, {}, 'wide'), (80, {}, 'medium'), (60, {}, 'narrow'), (40, {}, 'tiny'),
                                      (80, {'NO_COLOR': ''}, 'no-color'), (40, {'TERM': 'dumb'}, 'dumb')]:
            _, env = new_state(temp, label)
            raw = capture(columns, env, wrapper, (b'99\n', b'0\n'), extra)
            text = plain(raw)
            assert text.count(MAIN_PROMPT) == 2, (label, '无效选项后应回到菜单')
            screen = first_screen(text)
            over = [line for line in screen if width(line) > columns]
            assert not over, (label, columns, over)
            layout = (check_main_menu(screen, label), check_table(screen, label))
            assert layout == expected[label], (label, layout)
            if extra:
                assert '\x1b[' not in raw, (label, 'ANSI leaked')
            cases[label] = {'columns': columns, 'menu': layout[0], 'table': layout[1]}

        state, env = new_state(temp, 'notify')
        text = plain(capture(80, env, wrapper, (b'9\n', b'3\n', b'2\n', b'\n', b'0\n', b'0\n')))
        assert '推送范围  2/3 个监控项（不推送：m2）' in text, text[-2000:]
        toggle = text.split('选择推送的监控项 · ')
        assert len(toggle) >= 3 and '[ ] m2' in toggle[1] and '[✓] m2' in toggle[2], text[-2000:]
        assert '推送范围已更新：全部 3 个监控项' in text, text[-2000:]
        monitors = json.loads((state / 'config.json').read_text())['monitors']
        assert monitors['m2']['notify'] is True and 'notify' not in monitors['m1'] and 'notify' not in monitors['m3'], monitors
        assert max(map(width, text.split('\n'))) <= 80
        cases['notify-toggle'] = {'m2.notify': True}

        _, env = new_state(temp, 'edit')
        text = plain(capture(100, env, wrapper, (b'2\n', b'1\n', b'0\n', b'0\n')))
        assert '当前成员  7023,7031,7032,7082' in text and '请选择 [0-5]' in text and ' 修改端口' in text, text[-2000:]
        cases['edit-menu'] = {'passed': True}

        # 菜单动作失败（导入不存在的文件）只提示并回到菜单；2.0.0 中 set -e 会直接结束脚本（rc=1）。
        failed = subprocess.run(['/bin/bash', str(wrapper), str(PRODUCT)], input='14\n2\n/nonexistent.tgz\n\n0\n',
                                capture_output=True, text=True, timeout=20, env=new_state(temp, 'failed-action')[1])
        assert failed.returncode == 0 and '文件不存在' in failed.stdout + failed.stderr, failed
        cases['failed-action-stays-in-menu'] = {'passed': True}

        # 动作内部仍是 set -e：出错那一步之后不再执行，并回到菜单（不能用 `|| true` 把 errexit 整个关掉）。
        errexit = write_wrapper(temp, 'errexit', 'menu_bandwidth() { echo ACTION-START; false; echo ACTION-AFTER-FAILURE; }')
        run = subprocess.run(['/bin/bash', str(errexit), str(PRODUCT)], input='5\n0\n', capture_output=True, text=True,
                             timeout=20, env=new_state(temp, 'errexit')[1])
        assert run.returncode == 0 and 'ACTION-START' in run.stdout and 'ACTION-AFTER-FAILURE' not in run.stdout, run
        assert run.stdout.count(DASHBOARD) == 2, run.stdout[-1500:]
        cases['errexit-inside-action'] = {'passed': True}

        # 卸载：取消后回到菜单（2.0.0 取消也会退出菜单），确认后退出菜单。
        # 会动到宿主的函数全部换成桩，安装路径、快捷命令与恢复服务文件指向临时目录。
        uninstall = write_wrapper(temp, 'uninstall', '\n'.join((
            'cron_remove_all() { echo STUB-cron; }', 'begin_tc_update() { return 1; }',
            'cleanup_tc_recovery_files_if_unused() { :; }', 'nft_table_exists() { return 1; }',
            'nft() { echo "STUB-nft $*"; }', 'tc() { :; }', 'crontab() { echo "STUB-crontab $*"; }',
            'systemctl() { :; }')))
        for answer, label in (('n', 'cancel'), ('y', 'confirm')):
            state, env = new_state(temp, f'uninstall-{label}')
            env.update(PORT_TRAFFIC_DOG_INSTALL_PATH=str(state / 'bin' / 'port-traffic-dog.sh'),
                       PORT_TRAFFIC_DOG_SHORTCUT_PATH=str(state / 'bin' / 'dog'),
                       TRAFFIC_TOOLS_TC_LOCK_FILE=str(state / 'tc.lock'),
                       TRAFFIC_TOOLS_TC_RECOVERY_RUNNER=str(state / 'runner.sh'),
                       TRAFFIC_TOOLS_TC_RECOVERY_UNIT_FILE=str(state / 'runner.service'))
            run = subprocess.run(['/bin/bash', str(uninstall), str(PRODUCT)], input=f'17\n{answer}\n0\n',
                                 capture_output=True, text=True, timeout=20, env=env)
            out = run.stdout + run.stderr
            assert run.returncode == 0, (label, run)
            if label == 'cancel':
                assert '已取消' in out and run.stdout.count(DASHBOARD) == 2 and (state / 'config.json').exists(), out[-1500:]
            else:
                assert '卸载完成' in out and run.stdout.count(DASHBOARD) == 1 and not state.exists(), out[-1500:]
            cases[f'uninstall-{label}'] = {'passed': True}

        # select_monitor 在 $(...) 里画表：stdout 被捕获、stdin 不是终端时，列数要从 stderr 所连的终端读取
        # （曾写成 `stty size 2>/dev/null <&2`，stdin 被指向 /dev/null，只能退回 $COLUMNS）。
        # bash 5 默认开启 checkwinsize，执行外部命令后会按 stderr 终端改写 COLUMNS，正好掩盖这个错误，
        # 所以这里先关掉 checkwinsize，并把 COLUMNS 设成 80：只有真正从 stderr 读到终端宽度才会得到 120。
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 120, 0, 0))
        try:
            probe = subprocess.run(
                ['/bin/bash', '-c', 'shopt -u checkwinsize; source <(sed \'$d\' "$1"); '
                 'nft_read_values() { cat "$PTD_TEST_VALUES"; }; '
                 'ui_columns; echo; show_monitor_table', 'x', str(PRODUCT)],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=slave, text=True, timeout=20,
                env=dict(new_state(temp, 'stderr-tty')[1], COLUMNS='80'))
        finally:
            os.close(slave)
            os.close(master)
        assert probe.returncode == 0 and probe.stdout.split('\n')[0] == '120' and '█' in probe.stdout, probe.stdout
        cases['columns-from-stderr-tty'] = {'columns': 120, 'table': 'wide'}

        redirect = subprocess.run(['/bin/bash', '-c', 'source <(sed \'$d\' "$1"); show_main_menu_options', 'test', str(PRODUCT)],
                                  capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
        assert redirect.returncode == 0 and '\x1b[' not in redirect.stdout
        eof = subprocess.run(['/bin/bash', str(wrapper), str(PRODUCT)], input='', capture_output=True, text=True,
                             timeout=20, env=new_state(temp, 'eof')[1])
        assert eof.returncode == 0, eof
        print(json.dumps({'cases': cases, 'redirected_no_color': True, 'eof_exit': True}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
