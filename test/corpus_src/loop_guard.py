import sys

class Bdb:
    def _set_stopinfo(self, *args, **kwargs):
        pass

    def set_continue(self):
        self._set_stopinfo(self.botframe, None, -1)
        if self.breaks:
            pass
        else:
            sys.settrace(None)
            frame = sys._getframe().f_back
            while frame and frame is not self.botframe:
                del frame.f_trace
                frame = frame.f_back


def del_subscr(d):
    del d["x"]
