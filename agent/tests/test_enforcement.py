import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from country_agent import enforcement
from country_agent.policy import PolicyValidationError, parse_feed

def mocked_ranges(code):
    return (
        parse_feed(b"1.1.1.0/24\n", 4),
        parse_feed(b"2606:4700::/32\n", 6),
    )

class EnforcementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.directory = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_country_input_rejected(self):
        for invalid in (["CN", "CN"], ["cn"], ["ZZ"], ["CN", 4], "CN"):
            with self.subTest(invalid=invalid), self.assertRaises((PolicyValidationError, TypeError)):
                enforcement.normalize_countries(invalid)

    @patch.object(enforcement, "execute_batch")
    @patch.object(enforcement, "nft_exists", return_value=False)
    @patch.object(enforcement, "fetch_ranges", side_effect=mocked_ranges)
    def test_apply_persists_only_after_valid_nft_transaction(self, fetch, exists, exec_batch):
        response = enforcement.apply(self.directory, ["CN"])
        self.assertTrue(response["applied"])
        self.assertEqual(response["countries"], ["CN"])
        self.assertEqual(enforcement.load_policy(self.directory)["countries"], ["CN"])
        self.assertIn("table inet four_n6_geo", (self.directory / "active.nft").read_text())
        self.assertEqual(exec_batch.call_count, 1)

    @patch.object(enforcement, "execute_batch", side_effect=RuntimeError("nft failed"))
    @patch.object(enforcement, "nft_exists", return_value=False)
    @patch.object(enforcement, "fetch_ranges", side_effect=mocked_ranges)
    def test_failed_apply_does_not_persist(self, fetch, exists, exec_batch):
        with self.assertRaises(RuntimeError):
            enforcement.apply(self.directory, ["CN"])
        self.assertFalse((self.directory / "policy.json").exists())

    @patch.object(enforcement, "execute_batch")
    @patch.object(enforcement, "nft_exists", return_value=True)
    def test_disable_only_own_table(self, exists, exec_batch):
        result = enforcement.apply(self.directory, [])
        self.assertEqual(result["countries"], [])
        self.assertEqual(exec_batch.call_args.args[0], "delete table inet four_n6_geo\n")

    @patch.object(enforcement, "execute_batch")
    @patch.object(enforcement, "nft_exists", return_value=False)
    @patch.object(enforcement, "fetch_ranges", side_effect=mocked_ranges)
    def test_restart_restore_uses_saved_rules(self, fetch, exists, exec_batch):
        enforcement.apply(self.directory, ["CN"])
        response = enforcement.restore(self.directory)
        self.assertTrue(response["restored"])
        self.assertEqual(response["countries"], ["CN"])
        self.assertEqual(exec_batch.call_count, 2)

    @patch.object(enforcement, "execute_batch")
    @patch.object(enforcement, "nft_exists", return_value=False)
    @patch.object(enforcement, "fetch_ranges", side_effect=mocked_ranges)
    def test_refresh_retains_country_selections(self, fetch, exists, exec_batch):
        enforcement.apply(self.directory, ["CN"])
        enforcement.apply(self.directory, ["CN"], refresh=True)
        self.assertEqual(enforcement.load_policy(self.directory)["countries"], ["CN"])

if __name__ == "__main__":
    unittest.main()
