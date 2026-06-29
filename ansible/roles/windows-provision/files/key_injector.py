#!/usr/bin/env python3
"""
Key injector for Windows VM boot prompt.
Uses virtctl console via PTY to send a space keypress.
Simple approach: fork virtctl, write space to PTY, done.
"""
import pty
import os
import sys
import time
import signal
import select

VM_NAME = sys.argv[1] if len(sys.argv) > 1 else "win11-test-01"
NAMESPACE = sys.argv[2] if len(sys.argv) > 2 else "virt-windows"

print(f"[{time.ctime()}] Connecting to {VM_NAME} console...")

master, slave = pty.openpty()
pid = os.fork()

if pid == 0:
    # Child: run virtctl console
    os.close(master)
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(slave)
    os.execvp("virtctl", [
        "virtctl", "console", VM_NAME,
        "-n", NAMESPACE
    ])
else:
    # Parent: wait for virtctl to connect, then send key
    os.close(slave)

    # Give virtctl time to establish connection
    for attempt in range(10):
        time.sleep(1)
        try:
            data = os.read(master, 4096)
            output = data.decode('utf-8', errors='replace')
            print(f"  [{attempt+1}s] {output.strip()}")
            if "Press any key" in output or "Successfully connected" in output:
                break
        except:
            pass

    # Send space key
    print("  Sending space key...")
    os.write(master, b' ')
    time.sleep(1)

    # Try to read response
    try:
        if select.select([master], [], [], 3)[0]:
            data = os.read(master, 4096)
            print(f"  Response: {data[:200].decode('utf-8', errors='replace')}")
    except:
        pass

    # Kill child
    try:
        os.kill(pid, signal.SIGINT)
        os.waitpid(pid, 0)
    except:
        pass

    os.close(master)
    print("  Done")
