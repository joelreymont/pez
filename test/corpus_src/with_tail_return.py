def with_tail_return(winreg):
    cvkey = 'SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion'
    with winreg.OpenKeyEx(winreg.HKEY_LOCAL_MACHINE, cvkey) as key:
        pass
    return winreg.QueryValueEx(key, 'EditionId')[0]
