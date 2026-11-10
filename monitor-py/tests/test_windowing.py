import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from scrcpy_monitor import windowing


class WindowingTest(unittest.TestCase):
    def test_mover_degrades_gracefully(self):
        mover = windowing.create_mover()
        try:
            if not mover.available():
                self.assertTrue(mover.reason)
                self.assertEqual(windowing.NoMover().find_windows([os.getpid()]), {})
            self.assertIsInstance(mover.find_windows([os.getpid()]) if mover.available() else {}, dict)
        finally:
            mover.close()

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS only')
    def test_mac_bindings_load(self):
        mover = windowing.MacMover()
        try:
            mover.available()
            self.assertIsInstance(mover.find_windows([os.getpid()]), dict)
        finally:
            mover.close()


if __name__ == '__main__':
    unittest.main()
