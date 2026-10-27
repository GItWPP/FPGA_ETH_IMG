"""Run the unchanged software suite and expose failures as Actions annotations."""
from pathlib import Path
import sys
import unittest


def annotation(value):
    return value.replace('%','%25').replace('\r','%0D').replace('\n','%0A')


def main():
    if hasattr(sys.stdout,'reconfigure'):sys.stdout.reconfigure(encoding='utf-8')
    if hasattr(sys.stderr,'reconfigure'):sys.stderr.reconfigure(encoding='utf-8')
    suite=unittest.defaultTestLoader.discover(str(Path(__file__).parent),pattern='test_*.py')
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    for test,traceback in result.failures+result.errors:
        print('::error title='+annotation(test.id())+'::'+annotation(traceback[-6000:]),flush=True)
    return 0 if result.wasSuccessful() else 1

if __name__=='__main__':raise SystemExit(main())
