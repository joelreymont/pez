import os
import time


class Proc:

    def __init__(self):
        self.returncode = None
        self._waitpid_lock = None
        self.pid = 0

    def _try_wait(self, wait_flags):
        return os.waitpid(self.pid, wait_flags)

    def _remaining_time(self, endtime):
        return endtime - time.time()

    def _handle_exitstatus(self, sts):
        self.returncode = sts

    def _wait(self, timeout):
        if self.returncode is not None:
            return self.returncode
        if timeout is not None:
            endtime = time.time() + timeout
            delay = 0.0005
            while True:
                if self._waitpid_lock.acquire(False):
                    try:
                        if self.returncode is not None:
                            break
                        pid, sts = self._try_wait(os.WNOHANG)
                        assert pid == self.pid or pid == 0
                        if pid == self.pid:
                            self._handle_exitstatus(sts)
                            break
                    finally:
                        self._waitpid_lock.release()
                remaining = self._remaining_time(endtime)
                if remaining <= 0:
                    raise TimeoutError(timeout)
                delay = min(delay * 2, remaining, 0.05)
                time.sleep(delay)
        else:
            while self.returncode is None:
                with self._waitpid_lock:
                    if self.returncode is not None:
                        break
                    pid, sts = self._try_wait(0)
                    if pid == self.pid:
                        self._handle_exitstatus(sts)
        return self.returncode
