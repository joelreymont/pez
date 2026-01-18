import os
import time

cmd_kill = False
cmd_shutdown = False
cmd_reboot = False

if __name__ == "__main__":
    while True:
        if cmd_kill:
            print("kill")
            os._exit(os.EX_OK)
        if cmd_shutdown:
            try:
                print("bye")
            except Exception:
                print("without bye")
            time.sleep(10)
            os.system("shutdown now")
        else:
            time.sleep(1)
        if cmd_reboot:
            time.sleep(10)
            os.system("reboot")
