import unittest

from country_agent.nft_rules import PRIORITY, TABLE, render_disable, render_replace, render_table
from country_agent.policy import PolicyValidationError, parse_feed

def families():
    return {"CN": (parse_feed(b"1.1.1.0/24\n", 4), parse_feed(b"2606:4700::/32\n", 6))}

class NftRenderTests(unittest.TestCase):
    def test_isolated_hook_and_set_rules(self):
        rules = render_table(families())
        self.assertIn(f"table inet {TABLE}", rules)
        self.assertIn(f"priority {PRIORITY}", rules)
        self.assertIn("ip saddr @blocked_v4 drop", rules)
        self.assertIn("ip6 saddr @blocked_v6 drop", rules)
        self.assertNotIn("flush ruleset", rules)
        self.assertNotIn("opengov_guard", rules)
        self.assertNotIn("crowdsec-chain", rules)

    def test_no_exemptions_or_port_restrictions(self):
        rules = render_table(families())
        self.assertNotIn("dport", rules)
        self.assertNotIn("established", rules)
        self.assertNotIn("accept\n        ip saddr", rules)

    def test_replacement_only_managed_table(self):
        rules = render_replace(families(), existing=True)
        self.assertTrue(rules.startswith(f"delete table inet {TABLE}\n"))
        self.assertEqual(rules.count("delete table"), 1)

    def test_first_install_does_not_delete(self):
        self.assertNotIn("delete table", render_replace(families(), existing=False))

    def test_disable_only_managed_table(self):
        self.assertEqual(render_disable(True), f"delete table inet {TABLE}\n")

    def test_empty_countries_fail_closed_as_configuration(self):
        with self.assertRaises(PolicyValidationError):
            render_table({})

    def test_mismatched_families_fail(self):
        with self.assertRaises(PolicyValidationError):
            render_table({"CN": (parse_feed(b"1.1.1.0/24\n", 4), parse_feed(b"8.8.8.0/24\n", 4))})

    def test_deduplicates_shared_ranges(self):
        policy = families()
        policy["RU"] = policy["CN"]
        rules = render_table(policy)
        self.assertEqual(rules.count("1.1.1.0/24"), 1)
        self.assertEqual(rules.count("2606:4700::/32"), 1)

if __name__ == "__main__":
    unittest.main()
