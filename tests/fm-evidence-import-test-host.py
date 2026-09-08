#!/usr/bin/env python3
"""Exercise Evidence Import Consent through an isolated test-only host."""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys


def fail(message):
    print("fm-evidence-import-test-host: {}".format(message), file=sys.stderr)
    return 1


def contained(path, directory):
    try:
        return os.path.commonpath((path, directory)) == directory
    except ValueError:
        return False


def registered_test_callers():
    current = os.getppid()
    callers = set()
    for _depth in range(3):
        callers.add(str(current))
        try:
            parent = subprocess.check_output(
                ["/bin/ps", "-o", "ppid=", "-p", str(current)],
                stderr=subprocess.DEVNULL,
                universal_newlines=True,
            ).strip()
        except (OSError, subprocess.CalledProcessError):
            break
        if not parent.isdigit() or parent in callers:
            break
        current = int(parent)
    return callers


def fixture_root(path):
    current = Path(path).resolve()
    for directory in (current, *current.parents):
        marker = directory / ".fm-test-fixture"
        if marker.is_file() and not marker.is_symlink():
            marker_stat = marker.stat()
            try:
                owner_pid = marker.read_text(encoding="utf-8").splitlines()[0]
            except (OSError, IndexError, UnicodeDecodeError):
                return None
            if (
                owner_pid in registered_test_callers()
                and marker_stat.st_uid == os.geteuid()
                and marker_stat.st_nlink == 1
                and marker_stat.st_mode & 0o022 == 0
            ):
                return str(directory)
            return None
    return None


def main(arguments):
    if len(arguments) != 3:
        return fail("usage: fm-evidence-import-test-host.py HOME WORKTREE CONTROL_RECORD")
    home = os.path.realpath(os.path.abspath(arguments[0]))
    worktree = os.path.realpath(os.path.abspath(arguments[1]))
    record = arguments[2]
    root = Path(__file__).resolve().parents[1]
    subject = root / "bin" / "fm-evidence-import-stage.py"
    isolated_root = fixture_root(home)
    if isolated_root is None or not contained(worktree, isolated_root):
        return fail("authority fixtures must stay inside one registered test root")
    if not subject.is_file() or subject.is_symlink():
        return fail("the evidence import executable is unavailable")

    controller, worker = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    child = os.fork()
    if child == 0:
        try:
            controller.close()
            os.dup2(worker.fileno(), 3, inheritable=True)
            if worker.fileno() != 3:
                worker.close()
            environment = os.environ.copy()
            environment.pop("NM_HOME", None)
            os.execve(subject, [str(subject), "admit"], environment)
        except Exception as error:
            print("fm-evidence-import-test-host: {}".format(error), file=sys.stderr)
            os._exit(1)

    worker.close()
    request = {
        "schema_version": "1.0",
        "operation": "admit",
        "state_root": home,
        "worktree": worktree,
        "control_record": record,
    }
    try:
        controller.send(json.dumps(request, separators=(",", ":")).encode("utf-8"))
        controller.shutdown(socket.SHUT_WR)
    except BrokenPipeError:
        pass
    _pid, status = os.waitpid(child, 0)
    controller.close()
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
