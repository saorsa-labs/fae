import unittest

from scripts.import_public_preference_data import (
    convert_helpsteer3_row,
    convert_toolpreference_row,
    convert_xlam_irrelevance_row,
    stable_sample,
)


class ImportPublicPreferenceDataTests(unittest.TestCase):
    def test_convert_helpsteer3_row_prefers_response1_for_negative_score(self):
        row = {
            "domain": "general",
            "language": "english",
            "context": [{"role": "user", "content": "Say hello."}],
            "response1": "Hello.",
            "response2": "Goodbye.",
            "overall_preference": -2,
        }

        converted = convert_helpsteer3_row(row)

        self.assertIsNotNone(converted)
        self.assertEqual(converted["chosen"][0]["content"], "Hello.")
        self.assertEqual(converted["rejected"][0]["content"], "Goodbye.")

    def test_convert_xlam_irrelevance_row_creates_no_tool_preference(self):
        row = {
            "query": "Who won the World Cup in 2018?",
            "tools": '[{"name":"calendar","description":"Read calendar events."}]',
            "answers": "[]",
        }

        converted = convert_xlam_irrelevance_row(row)

        self.assertIsNotNone(converted)
        self.assertIn("None of the available tools are relevant", converted["chosen"][0]["content"])
        self.assertIn("calendar", converted["rejected"][0]["content"])

    def test_convert_toolpreference_row_skips_identical_pairs(self):
        row = {
            "instruction": "system prompt",
            "input": "trajectory so far",
            "output": ["same", "same"],
            "id": 1,
            "category": "G1",
        }

        self.assertIsNone(convert_toolpreference_row(row))

    def test_convert_toolpreference_row_wraps_raw_trace(self):
        row = {
            "instruction": "tool docs here",
            "input": "history here",
            "output": ["Thought: do the concrete next step", "Thought: maybe try something"],
            "id": 42,
            "category": "G2",
        }

        converted = convert_toolpreference_row(row)

        self.assertIsNotNone(converted)
        self.assertIn("Imported ToolPreference example", converted["prompt"][1]["content"])
        self.assertEqual(converted["metadata"]["category"], "G2")

    def test_stable_sample_zero_limit_skips_source(self):
        records = [{"x": 1}, {"x": 2}]
        self.assertEqual(stable_sample(records, 0, 3407), [])


if __name__ == "__main__":
    unittest.main()
