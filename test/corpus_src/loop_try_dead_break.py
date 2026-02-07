def syscmd(supported_platforms=('win32', 'win16', 'dos')):
    import sys
    import subprocess
    if sys.platform not in supported_platforms:
        return ('', '', '')
    for cmd in ('ver', 'command /c ver', 'cmd /c ver'):
        try:
            out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True, shell=True)
            break
        except (OSError, subprocess.CalledProcessError):
            continue
    else:
        return ('', '', '')
    return out
