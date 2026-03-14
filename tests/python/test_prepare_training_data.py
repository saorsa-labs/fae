import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from scripts.prepare_training_data import (
    assistant_message_has_supervision,
    extract_sft_examples_from_json_blocks,
    extract_text_content,
    main,
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

    def test_tool_calls_only_assistant_message_counts_as_supervision(self) -> None:
        message = {
            "role": "assistant",
            "content": None,
            "tool_calls": [
                {
                    "type": "function",
                    "function": {"name": "web_search", "arguments": "{\"q\":\"test\"}"},
                }
            ],
        }

        self.assertTrue(assistant_message_has_supervision(message))

    def test_main_allows_sft_only_imports(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            imports_dir = root / "imports"
            output_dir = root / "out"
            imports_dir.mkdir(parents=True, exist_ok=True)
            (imports_dir / "sft_only.jsonl").write_text(
                json.dumps(
                    {
                        "messages": [
                            {"role": "system", "content": "You are Fae."},
                            {"role": "user", "content": "Hello"},
                            {"role": "assistant", "content": "Hi"},
                        ]
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            stdout = io.StringIO()
            argv = [
                "prepare_training_data.py",
                "--source-dir",
                str(root),
                "--imports-dir",
                str(imports_dir),
                "--output-dir",
                str(output_dir),
                "--split",
                "--skip-markdown-sources",
            ]

            with patch("sys.argv", argv), redirect_stdout(stdout):
                exit_code = main()

            self.assertEqual(exit_code, 0)
            self.assertTrue((output_dir / "sft_train.jsonl").exists())
            self.assertIn("SFT-only output was generated successfully.", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
