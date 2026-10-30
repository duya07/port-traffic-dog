#!/usr/bin/env python3
"""Prompt-driven terminal layout checks; source only function definitions."""
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
import sys
import tempfile
import termios
import time
import unicodedata

ROOT=Path(__file__).resolve().parents[1]
PRODUCT=ROOT/'port-traffic-dog.sh'
ANSI=re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')

def width(text):
    return sum(0 if unicodedata.combining(ch) else 2 if unicodedata.east_asian_width(ch) in 'WF' else 1 for ch in text)

def capture(columns, extra, wrapper, answer=b'0\n'):
    master,slave=pty.openpty()
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,columns,0,0))
    env=dict(os.environ,TERM='xterm-256color',COLUMNS=str(columns));env.pop('NO_COLOR',None);env.update(extra)
    proc=subprocess.Popen(['/bin/bash',str(wrapper),str(PRODUCT)],stdin=slave,stdout=slave,stderr=slave,env=env)
    os.close(slave);data=b'';sent=False;deadline=time.monotonic()+12
    try:
        while time.monotonic()<deadline:
            if select.select([master],[],[],.1)[0]:
                try:chunk=os.read(master,65536)
                except OSError as error:
                    if error.errno==errno.EIO:break
                    raise
                if not chunk:break
                data+=chunk
                if not sent and '请选择操作 [0-12]:'.encode() in data:
                    os.write(master,answer);sent=True
            elif proc.poll() is not None:break
        result=proc.wait(timeout=max(.1,deadline-time.monotonic()))
        assert sent and result==0,(sent,result,data.decode(errors='replace')[-1000:])
        return data.decode()
    finally:
        if proc.poll() is None:proc.kill();proc.wait()
        os.close(master)


def main():
    wrapper_text='''#!/bin/bash
source <(sed '$d' "$1")
get_active_ports() { :; }
get_daily_total_traffic() { printf '0B'; }
machine_traffic_summary() { :; }
dog_tc_status_label() { printf '空闲'; }
tc_auto_recovery_state() { printf '未启用'; }
show_main_menu
'''
    with tempfile.TemporaryDirectory(prefix='dog-menu-test-') as temp:
        wrapper=Path(temp)/'wrapper.sh';wrapper.write_text(wrapper_text)
        cases={}
        for columns,extra,label in [(80,{},'wide'),(40,{},'narrow'),(80,{'NO_COLOR':''},'no-color'),(40,{'TERM':'dumb'},'dumb')]:
            raw=capture(columns,extra,wrapper)
            text=ANSI.sub('',raw).replace('\r','')
            menu=[line for line in text.splitlines() if re.match(r'^\s*\d+\. ',line)]
            assert len(menu)==(9 if columns==80 else 13),(label,menu)
            if columns==80:
                second=[re.search(r'\s([2468])\. ',line) for line in menu[:4]]
                assert all(second),(label,menu)
                starts=[width(line[:match.start(1)-1]) for line,match in zip(menu[:4],second)]
                assert len(set(starts))==1,(label,starts,menu[:4])
            else:
                lines=text.splitlines();start=next(i for i,line in enumerate(lines) if re.match(r'^\s*1\. ',line))
                end=next(i for i,line in enumerate(lines[start:],start) if '请选择操作' in line)
                assert max(map(width,lines[start:end]))<=40,(label,lines[start:end])
            if extra:assert '\x1b[' not in raw,(label,'ANSI leaked')
            cases[label]={'passed':True,'columns':columns,'menu_rows':len(menu)}
        command='source <(sed \'$d\' "$1"); show_main_menu_options'
        redirect=subprocess.run(['/bin/bash','-c',command,'test',str(PRODUCT)],capture_output=True,text=True,timeout=10)
        assert redirect.returncode==0 and '\x1b[' not in redirect.stdout
        # Test the real menu loop with an EOF; it must not spin on an empty choice.
        eof=subprocess.run(['/bin/bash',str(wrapper),str(PRODUCT)],input='',capture_output=True,text=True,timeout=10)
        assert eof.returncode==0
        print(json.dumps({'cases':cases,'redirected_no_color':True,'eof_exit':True},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
