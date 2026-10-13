import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

# Importable both as `tests.<module>` (-t) and as a top-level module (-s only).
_ROOT = str(__import__("pathlib").Path(__file__).resolve().parents[1])  # linux/tools/learned-bias
if _ROOT not in __import__("sys").path:
    __import__("sys").path.insert(0, _ROOT)

from learned_bias import gpu


class GpuLockTests(unittest.TestCase):
    """With a temporary lock file and a mocked nvidia-smi (never the real
    lock or GPU)."""

    def test_lock_is_exclusive_and_released_on_close(self):
        with tempfile.TemporaryDirectory() as d, mock.patch.object(gpu, "gpu_processes", return_value=[]):
            path = str(Path(d) / "gpu.lock")
            first = gpu.acquire(path)
            with self.assertRaises(gpu.GpuBusy):
                gpu.acquire(path)
            first.close()
            gpu.acquire(path).close()

    def test_refuses_a_busy_gpu(self):
        with tempfile.TemporaryDirectory() as d:
            path = str(Path(d) / "gpu.lock")
            with mock.patch.object(gpu, "gpu_processes", return_value=[(os.getpid() + 1, "900")]):
                with self.assertRaises(gpu.GpuBusy):
                    gpu.acquire(path)
            # The failed attempt released the lock.
            with mock.patch.object(gpu, "gpu_processes", return_value=[]):
                gpu.acquire(path).close()


if __name__ == "__main__":
    unittest.main()
