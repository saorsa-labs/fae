import unittest

from scripts.generate_surgical_lane_data import (
    build_instruction_dpo,
    build_instruction_sft,
    build_memory_dpo,
    build_memory_sft,
)


class GenerateSurgicalLaneDataTests(unittest.TestCase):
    def test_instruction_sft_contains_exact_target_prompt(self) -> None:
        rows = build_instruction_sft()
        prompts = [row["messages"][1]["content"] for row in rows]
        self.assertTrue(any("Answer in one sentence only." in prompt for prompt in prompts))

    def test_memory_sft_contains_store_ignore_target(self) -> None:
        rows = build_memory_sft()
        assistant = [row["messages"][-1]["content"] for row in rows]
        self.assertIn("STORE: dietary preference = vegan", assistant)

    def test_dpo_rows_use_canonical_shape(self) -> None:
        rows = build_instruction_dpo() + build_memory_dpo()
        self.assertTrue(rows)
        row = rows[0]
        self.assertIn("prompt", row)
        self.assertIn("chosen", row)
        self.assertIn("rejected", row)
        self.assertEqual(row["chosen"][0]["role"], "assistant")


if __name__ == "__main__":
    unittest.main()
