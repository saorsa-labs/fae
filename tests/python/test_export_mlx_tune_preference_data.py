import unittest

from scripts.export_mlx_tune_preference_data import assistant_text, convert_record


class DummyTokenizer:
    def __init__(self):
        self.calls = []

    def apply_chat_template(self, messages, tokenize=False, add_generation_prompt=False):
        self.calls.append(
            {
                "tokenize": tokenize,
                "add_generation_prompt": add_generation_prompt,
            }
        )
        parts = []
        for message in messages:
            parts.append(f"{message['role']}:{message['content']}")
        if add_generation_prompt:
            parts.append("assistant:")
        return "\n".join(parts)


class ExportMLXTunePreferenceDataTests(unittest.TestCase):
    def test_assistant_text_joins_assistant_messages_only(self):
        messages = [
            {"role": "user", "content": "ignored"},
            {"role": "assistant", "content": "first"},
            {"role": "assistant", "content": [{"type": "text", "text": "second"}]},
        ]
        self.assertEqual(assistant_text(messages), "first\nsecond")

    def test_convert_record_formats_prompt_and_responses(self):
        tokenizer = DummyTokenizer()
        record = {
            "prompt": [
                {"role": "system", "content": "sys"},
                {"role": "user", "content": "hello"},
            ],
            "chosen": [
                {"role": "assistant", "content": "good"},
            ],
            "rejected": [
                {"role": "assistant", "content": "bad"},
            ],
        }

        converted = convert_record(tokenizer, record)

        self.assertEqual(
            converted,
            {
                "prompt": "system:sys\nuser:hello\nassistant:",
                "chosen": "good",
                "rejected": "bad",
            },
        )

    def test_convert_record_falls_back_when_tokenizer_lacks_enable_thinking(self):
        tokenizer = DummyTokenizer()
        record = {
            "prompt": [
                {"role": "user", "content": "hello"},
            ],
            "chosen": [
                {"role": "assistant", "content": "good"},
            ],
            "rejected": [
                {"role": "assistant", "content": "bad"},
            ],
        }

        converted = convert_record(tokenizer, record)

        self.assertEqual(converted["prompt"], "user:hello\nassistant:")
        self.assertEqual(
            tokenizer.calls,
            [
                {
                    "tokenize": False,
                    "add_generation_prompt": True,
                },
            ],
        )


class ThinkingAwareDummyTokenizer:
    def __init__(self):
        self.enable_thinking = None

    def apply_chat_template(
        self,
        messages,
        tokenize=False,
        add_generation_prompt=False,
        enable_thinking=None,
    ):
        self.enable_thinking = enable_thinking
        return "prompt"


class ExportMLXTunePreferenceDataThinkingTests(unittest.TestCase):
    def test_convert_record_disables_thinking_when_supported(self):
        tokenizer = ThinkingAwareDummyTokenizer()
        record = {
            "prompt": [
                {"role": "user", "content": "hello"},
            ],
            "chosen": [
                {"role": "assistant", "content": "good"},
            ],
            "rejected": [
                {"role": "assistant", "content": "bad"},
            ],
        }

        converted = convert_record(tokenizer, record)

        self.assertEqual(converted["prompt"], "prompt")
        self.assertFalse(tokenizer.enable_thinking)


if __name__ == "__main__":
    unittest.main()
