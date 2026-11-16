"""Ensure failed verification cannot reuse a successful earlier receipt."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"examples/moonlsm"))
import verify_reindex

class ReceiptTests(unittest.TestCase):
    def test_failures_replace_previous_success(self):
        for error in (ValueError("bad data"),RuntimeError("child failed"),subprocess.TimeoutExpired("moon",1)):
            with self.subTest(error=type(error).__name__), tempfile.TemporaryDirectory() as temp:
                target=Path(temp)/"report.json"
                target.write_text('{"ready":true,"run_id":"old"}')
                with patch.object(sys,"argv",["verify_reindex.py","--report",str(target)]), \
                     patch.object(verify_reindex,"verify_case",side_effect=error):
                    with self.assertRaises(SystemExit) as caught:
                        verify_reindex.main()
                self.assertEqual(caught.exception.code,1)
                report=json.loads(target.read_text())
                self.assertFalse(report["ready"])
                self.assertNotEqual(report["run_id"],"old")
                self.assertIsNotNone(report["failed_stage"])
if __name__=="__main__": unittest.main()
