import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from scrcpy_monitor.entry import run

if __name__ == '__main__':
    sys.exit(run())
