import unittest

from scripts.prepare_training_data import (
    extract_sft_examples_from_json_blocks,
    extract_text_content,
)


class PrepareTrainingDataTests(unittest.TestCase):
    def test_extract_text_content_handles_multimodal_lists(self) -> None:
        content = [
            {"type": "text", "text": "Look at this"},
            {"type": "image_url", "image_url": {"url": "file:///tmp/example.png"}},
            {"type": "text", "text": "and summarize it"},
        ]

        self.assertEqual(extract_text_content(content), "Look at this and summarize it")

    def test_extract_sft_examples_skips_non_dict_messages_instead_of_crashing(self) -> None:
        text = """```json
{"messages": ["bad", {"role": "assistant", "content": [{"type": "text", "text": "ok"}]}]}
```"""

        examples, errors = extract_sft_examples_from_json_blocks(text)

        self.assertEqual(examples, [])
        self.assertEqual(
            errors,
            ["SFT block 1: messages contains non-message entries, skipping"],
        )


if __name__ == "__main__":
    unittest.main()
