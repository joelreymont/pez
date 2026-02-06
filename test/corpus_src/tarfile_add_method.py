class T:
    name = None

    def _dbg(self, *args):
        pass

    def gettarinfo(self, name, arcname):
        return arcname

    def addfile(self, tarinfo, f=None):
        pass

    def add(self, name, arcname=None, recursive=True, *, filter=None):
        if arcname is None:
            arcname = name
        if self.name is not None and name == self.name:
            self._dbg(2, "skip")
            return None
        self._dbg(1, name)
        tarinfo = self.gettarinfo(name, arcname)
        if tarinfo is None:
            self._dbg(1, "unsupported")
            return None
        if filter is not None:
            tarinfo = filter(tarinfo)
            if tarinfo is None:
                self._dbg(2, "excluded")
                return None
        if tarinfo.isreg():
            self.addfile(tarinfo, None)
        elif tarinfo.isdir():
            self.addfile(tarinfo)
            if recursive:
                for f in []:
                    self.add(f, f, recursive, filter=filter)
        else:
            self.addfile(tarinfo)
        return None
