import unittest

from scripts.import_hf_lane_data import (
    convert_instruction_row,
    convert_toolace_row,
    convert_user_profile_update_row,
    convert_when2call_pref_row,
    convert_when2call_sft_row,
    convert_xlam_irrelevance_row,
    convert_xlam_tool_use_row,
    parse_profile_fields,
    parse_toolace_tool_calls,
)


class ImportHFLaneDataTests(unittest.TestCase):
    def test_convert_instruction_row_keeps_one_sentence_examples(self) -> None:
        row = {
            "messages": [
                {"role": "system", "content": ""},
                {"role": "user", "content": "Answer in one sentence only."},
                {"role": "assistant", "content": "I can do that in one sentence."},
            ],
            "capability_target": "instruction_following",
        }

        converted = convert_instruction_row(row)

        self.assertIsNotNone(converted)
        self.assertEqual(converted["messages"][1]["content"], "Answer in one sentence only.")

    def test_convert_xlam_tool_use_row_keeps_tool_call_only_assistant_turn(self) -> None:
        row = {
            "messages": [
                {"role": "user", "content": "Search the web for quantum computing."},
                {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [
                        {
                            "type": "function",
                            "function": {"name": "web_search", "arguments": "{\"q\":\"quantum computing\"}"},
                        }
                    ],
                },
            ],
            "tools": '[{"type":"function","function":{"name":"web_search","parameters":{"type":"object"}}}]',
            "extra": {"id": 1},
        }

        converted = convert_xlam_tool_use_row(row)

        self.assertIsNotNone(converted)
        self.assertEqual(converted["tools"][0]["function"]["name"], "web_search")

    def test_convert_xlam_irrelevance_row_keeps_direct_answer(self) -> None:
        row = {
            "messages": [
                {"role": "user", "content": "Tell me a short joke."},
                {"role": "assistant", "content": "Why do programmers confuse Halloween and Christmas? Because OCT 31 == DEC 25."},
            ],
            "tools": '[{"type":"function","function":{"name":"calendar","parameters":{"type":"object"}}}]',
            "extra": {"distill": "Qwen"},
        }

        converted = convert_xlam_irrelevance_row(row)

        self.assertIsNotNone(converted)
        self.assertEqual(converted["source"], "minpeter/xlam-irrelevance-7.5k-qwen2.5-72b-distill-parsed")

    def test_convert_when2call_sft_turn_parses_tool_call(self) -> None:
        row = {
            "tools": [
                {
                    "name": "get_weather",
                    "description": "Fetch weather for a specific city and include an unnecessarily long description that should be trimmed.",
                    "parameters": {
                        "type": "dict",
                        "properties": {
                            "city": {
                                "type": "string",
                                "description": "City name with more detail than training needs.",
                                "default": "Glasgow",
                            }
                        },
                    },
                }
            ],
            "messages": [
                {"role": "user", "content": "What's the weather in Glasgow?"},
                {
                    "role": "assistant",
                    "content": '<TOOLCALL>[{"name":"get_weather","arguments":{"city":"Glasgow"}}]</TOOLCALL>',
                },
            ],
        }

        converted = convert_when2call_sft_row(row)

        self.assertIsNotNone(converted)
        assistant = converted["messages"][-1]
        self.assertEqual(assistant["tool_calls"][0]["function"]["name"], "get_weather")
        tool = converted["tools"][0]["function"]
        self.assertLessEqual(len(tool["description"]), 80)
        self.assertNotIn("description", tool["parameters"]["properties"]["city"])
        self.assertNotIn("default", tool["parameters"]["properties"]["city"])

    def test_convert_when2call_pref_turn_preserves_chosen_and_rejected_text(self) -> None:
        row = {
            "tools": [],
            "messages": [{"role": "user", "content": "Tell me something encouraging."}],
            "chosen_response": {"role": "assistant", "content": "You've handled hard things before, and you can take this one step at a time."},
            "rejected_response": {"role": "assistant", "content": "Let me search the web for encouragement."},
        }

        converted = convert_when2call_pref_row(row)

        self.assertIsNotNone(converted)
        self.assertEqual(converted["chosen"][0]["content"], row["chosen_response"]["content"])
        self.assertEqual(converted["rejected"][0]["content"], row["rejected_response"]["content"])

    def test_parse_toolace_tool_calls_parses_single_call(self) -> None:
        parsed = parse_toolace_tool_calls('[Market Trends API(trend_type="MARKET_INDEXES", country="us")]')

        self.assertEqual(parsed[0]["function"]["name"], "Market Trends API")
        self.assertEqual(
            parsed[0]["function"]["arguments"],
            {"trend_type": "MARKET_INDEXES", "country": "us"},
        )

    def test_convert_toolace_row_extracts_tools_and_call(self) -> None:
        row = {
            "system": (
                "You are an expert in composing functions.\n"
                "Here is a list of functions in JSON format that you can invoke:\n"
                '[{"name":"Market Trends API","description":"Get trends","parameters":{"type":"dict","properties":{"country":{"type":"string"}}}}]'
            ),
            "conversations": [
                {"from": "user", "value": "Show me US market trends."},
                {"from": "assistant", "value": '[Market Trends API(country="us")]'},
            ],
        }

        converted = convert_toolace_row(row)

        self.assertIsNotNone(converted)
        self.assertEqual(converted["tools"][0]["function"]["name"], "Market Trends API")
        self.assertEqual(converted["messages"][-1]["tool_calls"][0]["function"]["name"], "Market Trends API")

    def test_convert_toolace_row_limits_tools_and_keeps_called_tool(self) -> None:
        row = {
            "system": (
                "You are an expert in composing functions.\n"
                "Here is a list of functions in JSON format that you can invoke:\n"
                '[{"name":"Tool 1","description":"One","parameters":{"type":"dict","properties":{"x":{"type":"string"}}}},'
                '{"name":"Tool 2","description":"Two","parameters":{"type":"dict","properties":{"x":{"type":"string"}}}},'
                '{"name":"Tool 3","description":"Three","parameters":{"type":"dict","properties":{"x":{"type":"string"}}}},'
                '{"name":"Tool 4","description":"Four","parameters":{"type":"dict","properties":{"x":{"type":"string"}}}},'
                '{"name":"Tool 5","description":"Five","parameters":{"type":"dict","properties":{"x":{"type":"string"}}}}]'
            ),
            "conversations": [
                {"from": "user", "value": "Use tool 5 please."},
                {"from": "assistant", "value": '[Tool 5(x="value")]'},
            ],
        }

        converted = convert_toolace_row(row)

        self.assertIsNotNone(converted)
        self.assertLessEqual(len(converted["tools"]), 4)
        self.assertEqual(converted["tools"][0]["function"]["name"], "Tool 5")

    def test_parse_profile_fields_extracts_markdown_fields(self) -> None:
        markdown = """**Name:** Jane Doe
**Likes:** Gardening
**Dislikes:** Unknown
"""

        parsed = parse_profile_fields(markdown)

        self.assertEqual(parsed, {"name": "Jane Doe", "likes": "Gardening"})

    def test_convert_user_profile_update_row_renders_store_and_supersede_lines(self) -> None:
        row = {
            "Input": "Jane loves gardening and now works as a botanist in Glasgow.",
            "Old_profile": """**Profession:** Teacher
**Likes:** Gardening
""",
            "Update_profile": """**Profession:** Botanist
**Likes:** Gardening
**Birth Place:** Glasgow
""",
        }

        converted = convert_user_profile_update_row(row)

        self.assertIsNotNone(converted)
        assistant = converted["messages"][-1]["content"]
        self.assertIn("SUPERSEDE: profession = Botanist", assistant)
        self.assertIn("STORE: birth_place = Glasgow", assistant)


if __name__ == "__main__":
    unittest.main()
