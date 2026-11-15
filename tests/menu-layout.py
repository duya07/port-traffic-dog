#!/usr/bin/env python3
"""Dog 2.0 主菜单布局：在伪终端里运行真实的循环菜单（只替换会读 nft 的仪表盘），
检查两列对齐、窄屏单列不超宽、NO_COLOR/TERM=dumb 无 ANSI、重定向无颜色、EOF 退出码为 0。"""
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
PROMPT = '请选择操作: '.encode()
ROW = re.compile(r'^\s*\d+\. ')


def width(text):
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in text)


def capture(columns, extra, wrapper, answers=(b'99\n', b'0\n')):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, columns, 0, 0))
    env = dict(os.environ, TERM='xterm-256color', COLUMNS=str(columns))
    env.pop('NO_COLOR', None)
    env.update(extra)
    proc = subprocess.Popen(['/bin/bash', str(wrapper), str(PRODUCT)], stdin=slave, stdout=slave, stderr=slave, env=env)
    os.close(slave)
    data = b''
    sent = 0
    deadline = time.monotonic() + 15
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
                # 每出现一次新提示就回答一次：先给无效选项（应回到菜单），再给 0 退出。
                if sent < len(answers) and data.count(PROMPT) > sent:
                    os.write(master, answers[sent])
                    sent += 1
            elif proc.poll() is not None:
                break
        result = proc.wait(timeout=max(.1, deadline - time.monotonic()))
        assert sent == len(answers) and result == 0, (sent, result, data.decode(errors='replace')[-1000:])
        return data.decode()
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()
        os.close(master)


def first_menu(text):
    lines = text.splitlines()
    start = next(i for i, line in enumerate(lines) if re.match(r'^\s*1\. ', line))
    end = next(i for i, line in enumerate(lines[start:], start) if '请选择操作' in line)
    return lines[start:end]


def main():
    labels = int(subprocess.run(
        ['/bin/bash', '-c', 'source <(sed \'$d\' "$1"); echo "${#MAIN_MENU_LABELS[@]}"', 'x', str(PRODUCT)],
        capture_output=True, text=True, timeout=10, env=dict(os.environ, NO_COLOR='1')).stdout.strip())
    assert labels >= 10, labels
    wrapper_text = '''#!/bin/bash
source <(sed '$d' "$1")
show_dashboard() { echo "=== 测试仪表盘 ==="; }
pause() { :; }
show_main_menu
'''
    with tempfile.TemporaryDirectory(prefix='dog-menu-test-') as temp:
        wrapper = Path(temp) / 'wrapper.sh'
        wrapper.write_text(wrapper_text)
        cases = {}
        for columns, extra, label in [(100, {}, 'wide'), (80, {}, 'medium'), (40, {}, 'narrow'),
                                      (80, {'NO_COLOR': ''}, 'no-color'), (40, {'TERM': 'dumb'}, 'dumb')]:
            raw = capture(columns, extra, wrapper)
            text = ANSI.sub('', raw).replace('\r', '')
            assert text.count('请选择操作') == 2, (label, '无效选项后应回到菜单')
            menu = first_menu(text)
            rows = [line for line in menu if ROW.match(line)]
            assert max(map(width, menu)) <= columns, (label, menu)
            if columns >= 80:
                pairs = (labels + 1) // 2
                assert len(rows) == pairs + 1, (label, rows)
                starts = []
                for line in rows[:labels // 2]:
                    match = re.search(r'\s(\d+)\. ', line[4:])
                    assert match, (label, line)
                    starts.append(width(line[:4 + match.end(1)]))  # 编号右对齐：以 “.” 位置为准
                assert len(set(starts)) == 1, (label, starts, rows)
            else:
                assert len(rows) == labels + 1, (label, rows)
            if extra:
                assert '\x1b[' not in raw, (label, 'ANSI leaked')
            cases[label] = {'passed': True, 'columns': columns, 'menu_rows': len(rows)}
        redirect = subprocess.run(['/bin/bash', '-c', 'source <(sed \'$d\' "$1"); show_main_menu_options', 'test', str(PRODUCT)],
                                  capture_output=True, text=True, timeout=10)
        assert redirect.returncode == 0 and '\x1b[' not in redirect.stdout
        eof = subprocess.run(['/bin/bash', str(wrapper), str(PRODUCT)], input='', capture_output=True, text=True, timeout=10)
        assert eof.returncode == 0, eof
        print(json.dumps({'cases': cases, 'redirected_no_color': True, 'eof_exit': True}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
