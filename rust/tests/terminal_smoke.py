"""Unix PTY acceptance check; uses isolated configuration and no network."""
import errno
import fcntl
import json
import os
import pathlib
import pty
import re
import select
import signal
import struct
import sys
import tempfile
import termios
import time


def run(binary, settings=False, mouse=False):
    with tempfile.TemporaryDirectory(prefix="pxder-tui-test-") as temp:
        config = pathlib.Path(temp) / "config"
        pid, master = pty.fork()
        if pid == 0:
            os.environ["TERM"] = "xterm-256color"
            os.execv(binary, [binary, "--config-dir", str(config)] + (["--setting"] if settings else []))
        output = bytearray()
        exited = False
        try:
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 32, 100, 0, 0))

            def receive(seconds=0.3):
                end = time.monotonic() + seconds
                while time.monotonic() < end:
                    readable, _, _ = select.select([master], [], [], 0.05)
                    if readable:
                        try:
                            chunk = os.read(master, 65536)
                        except OSError as error:
                            if error.errno == errno.EIO:
                                return
                            raise
                        if not chunk:
                            return
                        output.extend(chunk)
                        # Respond to the cursor-position query used at startup.
                        if b"\x1b[6n" in chunk:
                            os.write(master, b"\x1b[1;1R")

            def send(data):
                os.write(master, data)
                receive()

            def click(column, row):
                # SGR mouse protocol: terminal positions are one-based.
                send(f"\x1b[<0;{column};{row}M\x1b[<0;{column};{row}m".encode())

            def plain_output():
                return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", bytes(output))

            receive(1)
            if settings:
                assert "下载目录".encode() in plain_output()
                for _ in range(3):
                    send(b"\r")
                assert "代理（输入隐藏）".encode() in plain_output()
                assert not termios.tcgetattr(master)[3] & termios.ECHO
                send(b"SECRET_PROXY_PASSWORD")
                assert b"SECRET_PROXY_PASSWORD" not in plain_output()
                send(b"\x03")
                assert not (config / "config.json").exists()
            elif mouse:
                assert b"\x1b[?1006h" in output, "mouse capture was not enabled"
                click(14, 30)  # Dashboard: Settings
                assert "下载设置".encode() in plain_output()
                click(15, 9)  # Download directory input
                send(b"\x15" + str(pathlib.Path(temp) / "mouse-images").encode())
                click(16, 17)  # Toggle auto rename, including mouse release
                click(15, 26)  # Save settings
                saved = json.loads((config / "config.json").read_text())
                assert saved["download"]["path"] == str(pathlib.Path(temp) / "mouse-images")
                assert saved["download"]["autoRename"] is True
                click(3, 30)  # New job
                click(29, 10)  # Next source: PID
                assert "作品".encode() in plain_output()  # Unchanged "ID" cells are not repainted.
                click(15, 15)  # ID input
                send(b"123")
                click(15, 25)  # Submit uses normal validation
                assert "请先登录".encode() in plain_output()
                click(47, 25)  # Back
                click(51, 30)  # Quit
            else:
                assert b"PXDER" in output, output.decode(errors="replace")[-2000:]
                raw_flags = termios.tcgetattr(master)[3]
                assert not raw_flags & termios.ICANON
                send(b"s")
                send(b"\x15" + str(pathlib.Path(temp) / "images").encode())
                send(b"\r")
                saved = json.loads((config / "config.json").read_text())
                assert saved["download"]["path"] == str(pathlib.Path(temp) / "images")
                send(b"n")
                send(b"\x1b[C")  # Select PID, then focus its ID field
                send(b"\t")
                send(b"123")
                send(b"\r")
                assert "请先登录".encode() in plain_output()
                send(b"\x1b")
                send(b"l")
                send(b"t")
                secret = b"PTY_SENTINEL_TOKEN"
                send(secret)
                assert secret not in plain_output()
                send(b"\x1b")
                send(b"?")
                send(b"\x1b")
                send(b"g")
                send(b"\x1b")
                send(b"q")
            deadline = time.monotonic() + 3
            status = None
            while time.monotonic() < deadline:
                waited, status = os.waitpid(pid, os.WNOHANG)
                if waited:
                    exited = True
                    break
                receive(0.1)
            assert exited, "TUI did not exit"
            assert os.waitstatus_to_exitcode(status) == (130 if settings else 0)
            if not settings:
                assert b"\x1b[?1049l" in output, "alternate screen was not restored"
                assert b"\x1b[?1006l" in output, "mouse capture was not disabled"
                assert b"\x1b[?2004l" in output, "bracketed paste was not disabled"
            flags = termios.tcgetattr(master)[3]
            assert flags & termios.ICANON and flags & termios.ECHO, "terminal mode was not restored"
            print("PASS: CLI hidden input cancellation and terminal restoration" if settings else
                  "PASS: TUI mouse navigation, input, toggle, submit and terminal restoration" if mouse else
                  "PASS: TUI settings, validation, secret masking, help, exit and terminal restoration")
        finally:
            if not exited:
                os.kill(pid, signal.SIGKILL)
                os.waitpid(pid, 0)
            os.close(master)


if __name__ == "__main__":
    binary = str(pathlib.Path(sys.argv[1]).resolve())
    run(binary)
    run(binary, mouse=True)
    run(binary, settings=True)
