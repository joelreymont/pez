_mswindows = True


class TimeoutExpired(Exception):

    def __init__(self, args, timeout):
        super().__init__()
        self.args = args
        self.timeout = timeout
        self.stdout = None
        self.stderr = None


def run_like(process, input = None, timeout = None):
    with process as proc:
        try:
            stdout, stderr = proc.communicate(input, timeout=timeout)
        except TimeoutExpired as exc:
            proc.kill()
            if _mswindows:
                exc.stdout, exc.stderr = proc.communicate()
            else:
                proc.wait()
            raise
        except:
            proc.kill()
            raise
        retcode = proc.poll()
    return (retcode, stdout, stderr)
