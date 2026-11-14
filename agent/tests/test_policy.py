import unittest
from country_agent.policy import PolicyValidationError, parse_feed, preview, validate_country

class PolicyTests(unittest.TestCase):
    v4 = b"1.1.1.0/24\n8.8.8.0/24\n"
    v6 = b"2606:4700::/32\n"

    def test_preview(self):
        result = preview("CN", self.v4, self.v6)
        self.assertEqual(result["country"], "CN")
        self.assertTrue(result["dry_run"])
        self.assertFalse(result["applied"])
        self.assertEqual(result["ipv4"]["cidr_count"], 2)
        self.assertEqual(result["ipv6"]["cidr_count"], 1)
        self.assertNotIn("cidrs", result["ipv4"])

    def test_explicit_ranges(self):
        self.assertEqual(len(preview("CN", self.v4, self.v6, True)["ipv4"]["cidrs"]), 2)

    def test_invalid_countries(self):
        for code in ["cn", "ZZ", "CN;", "", "X"]:
            with self.subTest(code=code), self.assertRaises(PolicyValidationError):
                validate_country(code)

    def test_missing_ipv6_rejected(self):
        with self.assertRaises(PolicyValidationError):
            preview("CN", self.v4, b"")

    def test_family_mismatch(self):
        with self.assertRaises(PolicyValidationError):
            parse_feed(self.v6, 4)

    def test_non_global_and_blanket_rejected(self):
        for feed in [b"10.0.0.0/8\n", b"127.0.0.0/8\n", b"0.0.0.0/0\n", b"192.168.1.0/24\n"]:
            with self.subTest(feed=feed), self.assertRaises(PolicyValidationError):
                parse_feed(feed, 4)

    def test_invalid_syntax_rejected(self):
        for feed in [b"1.1.1.0/24; rm -rf /\n", b"1.1.1.1\n", b"1.1.1.1/24\n"]:
            with self.subTest(feed=feed), self.assertRaises(PolicyValidationError):
                parse_feed(feed, 4)

    def test_duplicates_deduped(self):
        self.assertEqual(parse_feed(self.v4 + b"1.1.1.0/24\n", 4).as_dict()["cidr_count"], 2)

    def test_oversize_rejected(self):
        with self.assertRaises(PolicyValidationError):
            parse_feed(b"x" * (16 * 1024 * 1024 + 1), 4)

if __name__ == "__main__":
    unittest.main()
