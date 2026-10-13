"""Exclusive GPU use: an fcntl lock shared with other training jobs, plus a
check that no other process is using the GPU."""

import fcntl
import os
import subprocess
import time

from .env import gpu_lock


class GpuBusy(RuntimeError):
    pass


def gpu_processes():
    """(pid, used MiB) of every compute process on any GPU, via nvidia-smi."""
    out = subprocess.run(
        ["nvidia-smi", "--query-compute-apps=pid,used_memory", "--format=csv,noheader,nounits"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    procs = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2 and parts[0].isdigit():
            procs.append((int(parts[0]), parts[1]))
    return procs


def acquire(path=None, wait=False, poll=30.0):
    """Take the exclusive lock (`path`, else LF_GPU_LOCK; held until the
    returned file is closed or the process exits) and check the GPU is idle.
    Call before CUDA is initialized, so this process is not among the GPU's
    users."""
    path = gpu_lock(path)
    f = open(path, "a+")
    while True:
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if not wait:
                f.close()
                raise GpuBusy(f"{path} is held by another job") from None
            time.sleep(poll)
    others = [p for p in gpu_processes() if p[0] != os.getpid()]
    if others:
        f.close()
        raise GpuBusy(f"GPU is not idle: compute processes {others}")
    f.seek(0)
    f.truncate()
    f.write(f"{os.getpid()} learned-bias train\n")
    f.flush()
    return f
