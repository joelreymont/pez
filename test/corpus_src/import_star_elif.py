from mod import *
import sys
if sys.platform == 'cli':
    from mod2 import Serial
else:
    import os
    if os.name == 'nt':
        from mod3 import Serial
    elif os.name == 'posix':
        from mod4 import Serial
    else:
        raise ImportError('no impl')
