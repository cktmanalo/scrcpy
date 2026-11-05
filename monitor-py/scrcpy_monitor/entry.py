import sys


def run(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) == 2 and argv[0] == '--send-ctrl-c':
        from .system import send_ctrl_c_main
        return send_ctrl_c_main(int(argv[1]))
    from .app import main
    return main(argv)
