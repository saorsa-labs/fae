#!/usr/bin/env python3
"""Import isolated Hugging Face training lanes into Fae's canonical JSONL format.

Writes lane-specific canonical rows under:
  training/imports/hf-lanes/<lane>/*.jsonl

Primary lanes:
  - when2call: SFT + preference rows from nvidia/When2Call
  - toolace: tool-planning SFT rows from Team-ACE/ToolACE
  - user-profile: memory-update SFT rows from Nusrat1234/UserProfileUpdate

Legacy lanes remain available for comparison:
  - instruction
  - tool-balance
  - memory
"""

from __future__ import annotations

import argparse
import ast
import json
import re
from pathlib import Path
from typing import Iterable


INSTRUCTION_PATTERNS = [
    re.compile(pattern, re.IGNORECASE)
    for pattern in [
        r"\bone sentence\b",
        r"\bsingle sentence\b",
        r"\bexactly one sentence\b",
        r"\bone line\b",
        r"\bsingle line\b",
        r"\bunder \d+ words\b",
        r"\bless than \d+ sentences\b",
    ]
]

TOOLACE_SYSTEM_TOOLS_PATTERN = re.compile(
    r"Here is a list of functions in JSON format that you can invoke:\s*(\[[\s\S]+)$"
)
WHEN2CALL_TOOLCALL_PATTERN = re.compile(r"^\s*<TOOLCALL>\s*(.+?)\s*</TOOLCALL>\s*$", re.DOTALL)
TOKEN_PATTERN = re.compile(r"[a-z0-9]+")

MEMORY_FIELDS = {
    "name": "name",
    "birth place": "birth_place",
    "profession": "profession",
    "hobbies": "hobbies",
    "likes": "likes",
    "dislikes": "dislikes",
    "genre": "genre",
    "research interests": "research_interests",
    "treatment modalities": "treatment_modalities",
    "active years": "active_years",
}

MAX_TOOL_DESCRIPTION_CHARS = 48
MAX_TOOLS_PER_EXAMPLE = 3
MAX_PROPERTIES_PER_OBJECT = 4
MAX_ENUM_VALUES = 8
MAX_SCHEMA_DEPTH = 2
MAX_TOOLING_EXAMPLE_CHARS = 1500


def truncate(text: str, max_chars: int) -> str:
    text = text.strip()
    if len(text) <= max_chars:
        return text
    return text[: max_chars - 3].rstrip() + "..."


def write_jsonl(path: Path, records: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")


def canonical_sft(
    messages: list[dict],
    *,
    source: str,
    tools: list[dict] | None = None,
    metadata: dict | None = None,
) -> dict:
    record = {
        "messages": messages,
        "source": source,
    }
    if tools:
        record["tools"] = tools
    if metadata:
        record["metadata"] = metadata
    return record


def canonical_dpo(
    prompt: list[dict],
    chosen: list[dict],
    rejected: list[dict],
    *,
    source: str,
    metadata: dict | None = None,
) -> dict:
    record = {
        "prompt": prompt,
        "chosen": chosen,
        "rejected": rejected,
        "source": source,
    }
    if metadata:
        record["metadata"] = metadata
    return record


def serialized_length(value: object) -> int:
    return len(json.dumps(value, ensure_ascii=False))


def extract_text_content(content: object) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                text = item.get("text", "")
                if isinstance(text, str):
                    parts.append(text)
            elif isinstance(item, str):
                parts.append(item)
        return " ".join(parts)
    return ""


def normalize_messages(messages: Iterable[dict]) -> list[dict]:
    normalized: list[dict] = []
    for message in messages:
        role = message.get("role")
        if role not in {"system", "user", "assistant", "tool"}:
            continue
        normalized_message = {"role": role}
        if "content" in message:
            normalized_message["content"] = message.get("content")
        if "tool_calls" in message and message.get("tool_calls"):
            normalized_calls: list[dict] = []
            for call in message["tool_calls"]:
                if not isinstance(call, dict):
                    continue
                function = call.get("function")
                if not isinstance(function, dict):
                    continue
                arguments = function.get("arguments", {})
                if isinstance(arguments, str):
                    try:
                        parsed = json.loads(arguments)
                    except json.JSONDecodeError:
                        parsed = {}
                    arguments = parsed if isinstance(parsed, dict) else {}
                elif not isinstance(arguments, dict):
                    arguments = {}
                normalized_calls.append(
                    {
                        "type": "function",
                        "function": {
                            "name": str(function.get("name", "")).strip(),
                            "arguments": arguments,
                        },
                    }
                )
            if normalized_calls:
                normalized_message["tool_calls"] = normalized_calls
        if role == "tool" and "name" in message:
            normalized_message["name"] = message.get("name")
        normalized.append(normalized_message)
    return normalized


def parse_tools(value: str | list | None) -> list[dict]:
    if isinstance(value, list):
        return value
    if not isinstance(value, str) or not value.strip():
        return []
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return []
    return parsed if isinstance(parsed, list) else []


def normalize_schema(schema: object, depth: int = 0) -> dict:
    if not isinstance(schema, dict):
        return {}

    normalized = dict(schema)
    schema_type = normalized.get("type")
    if not isinstance(schema_type, str):
        schema_type = None
    if not schema_type:
        if isinstance(normalized.get("properties"), dict):
            schema_type = "object"
        elif "items" in normalized:
            schema_type = "array"
    if schema_type == "dict":
        schema_type = "object"
    elif schema_type == "str":
        schema_type = "string"
    elif schema_type == "int":
        schema_type = "integer"
    elif schema_type == "float":
        schema_type = "number"
    elif schema_type == "bool":
        schema_type = "boolean"

    if schema_type not in {"object", "array", "string", "integer", "number", "boolean"}:
        schema_type = None

    if schema_type is None and not normalized.get("properties") and "items" not in normalized and not normalized.get("enum"):
        return {}

    compacted: dict[str, object] = {"type": schema_type} if schema_type else {}

    enum = normalized.get("enum")
    if isinstance(enum, list):
        compact_enum: list[object] = []
        for value in enum:
            if len(compact_enum) >= MAX_ENUM_VALUES:
                break
            if isinstance(value, str):
                compact_enum.append(truncate(value, 24))
            elif isinstance(value, (int, float, bool)) or value is None:
                compact_enum.append(value)
        if compact_enum:
            compacted["enum"] = compact_enum

    if schema_type == "object":
        raw_properties = normalized.get("properties")
        compact_properties: dict[str, dict] = {}
        if isinstance(raw_properties, dict) and depth < MAX_SCHEMA_DEPTH:
            for index, (key, value) in enumerate(raw_properties.items()):
                if index >= MAX_PROPERTIES_PER_OBJECT:
                    break
                if not isinstance(key, str) or not key.strip():
                    continue
                compact_properties[key] = normalize_schema(value, depth + 1)
        compacted["properties"] = compact_properties

        required = normalized.get("required")
        if isinstance(required, list):
            compact_required = [
                item
                for item in required
                if isinstance(item, str) and item in compact_properties
            ]
            if compact_required:
                compacted["required"] = compact_required
    elif schema_type == "array" and depth < MAX_SCHEMA_DEPTH:
        compacted["items"] = normalize_schema(normalized.get("items"), depth + 1)

    return compacted


def normalize_tool_schema(tool: dict) -> dict | None:
    if isinstance(tool, str):
        try:
            tool = json.loads(tool)
        except json.JSONDecodeError:
            return None
    if not isinstance(tool, dict):
        return None

    if tool.get("type") == "function" and isinstance(tool.get("function"), dict):
        function = dict(tool["function"])
    else:
        name = str(tool.get("name", "")).strip()
        if not name:
            return None
        function = {
            "name": name,
            "description": str(tool.get("description", "")).strip(),
            "parameters": tool.get("parameters") or {"type": "object", "properties": {}},
        }

    name = str(function.get("name", "")).strip()
    if not name:
        return None

    parameters = normalize_schema(function.get("parameters"))
    if not parameters or parameters.get("type") != "object":
        parameters = {"type": "object", "properties": {}}

    compact_function = {"name": name, "parameters": parameters}
    description = truncate(str(function.get("description", "")).strip(), MAX_TOOL_DESCRIPTION_CHARS)
    if description:
        compact_function["description"] = description

    return {"type": "function", "function": compact_function}


def normalize_tool_schemas(tools: Iterable[dict]) -> list[dict]:
    normalized: list[dict] = []
    for tool in tools:
        normalized_tool = normalize_tool_schema(tool)
        if normalized_tool is not None:
            normalized.append(normalized_tool)
    return normalized


def extract_tool_names_from_message(message: dict) -> list[str]:
    names: list[str] = []
    for call in message.get("tool_calls") or []:
        if not isinstance(call, dict):
            continue
        function = call.get("function")
        if not isinstance(function, dict):
            continue
        name = str(function.get("name", "")).strip()
        if name:
            names.append(name)
    return names


def tokenize_keywords(text: str) -> set[str]:
    return {token for token in TOKEN_PATTERN.findall(text.lower().replace("_", " ")) if len(token) > 2}


def score_tool_relevance(tool: dict, query_text: str) -> tuple[int, int]:
    function = tool.get("function", {})
    name = str(function.get("name", ""))
    description = str(function.get("description", ""))
    parameters = function.get("parameters", {})
    property_names = []
    if isinstance(parameters, dict):
        raw_properties = parameters.get("properties")
        if isinstance(raw_properties, dict):
            property_names = list(raw_properties)

    query_tokens = tokenize_keywords(query_text)
    tool_tokens = tokenize_keywords(" ".join([name, description, *property_names]))
    overlap = len(query_tokens & tool_tokens)
    exact_name_hit = 1 if name.lower().replace("_", " ") in query_text.lower() else 0
    return (overlap, exact_name_hit)


def limit_tools_for_example(
    tools: Iterable[dict],
    *,
    query_text: str = "",
    preferred_names: Iterable[str] = (),
    max_tools: int = MAX_TOOLS_PER_EXAMPLE,
) -> list[dict]:
    normalized = normalize_tool_schemas(tools)
    if not normalized:
        return []

    ordered_names = [name for name in preferred_names if isinstance(name, str) and name.strip()]
    chosen: list[dict] = []
    seen_names: set[str] = set()

    for name in ordered_names:
        for tool in normalized:
            tool_name = tool["function"]["name"]
            if tool_name != name or tool_name in seen_names:
                continue
            chosen.append(tool)
            seen_names.add(tool_name)
            break
        if len(chosen) >= max_tools:
            return chosen

    ranked_tools = sorted(
        normalized,
        key=lambda tool: score_tool_relevance(tool, query_text),
        reverse=True,
    )

    for tool in ranked_tools:
        tool_name = tool["function"]["name"]
        if tool_name in seen_names:
            continue
        chosen.append(tool)
        seen_names.add(tool_name)
        if len(chosen) >= max_tools:
            break

    return chosen


def canonical_tool_calls(raw_calls: list[dict]) -> list[dict]:
    tool_calls: list[dict] = []
    for call in raw_calls:
        if not isinstance(call, dict):
            continue
        name = str(call.get("name", "")).strip()
        arguments = call.get("arguments", {})
        if not name or not isinstance(arguments, dict):
            continue
        tool_calls.append(
            {
                "type": "function",
                "function": {
                    "name": name,
                    "arguments": arguments,
                },
            }
        )
    return tool_calls


def parse_when2call_tool_calls(content: str) -> list[dict]:
    match = WHEN2CALL_TOOLCALL_PATTERN.match(content.strip())
    if match is None:
        return []
    try:
        payload = json.loads(match.group(1))
    except json.JSONDecodeError:
        return []
    if not isinstance(payload, list):
        return []
    return canonical_tool_calls(payload)


def split_top_level(text: str, delimiter: str = ",") -> list[str]:
    parts: list[str] = []
    current: list[str] = []
    depth_paren = 0
    depth_bracket = 0
    depth_brace = 0
    quote: str | None = None
    escaped = False

    for char in text:
        if quote is not None:
            current.append(char)
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == quote:
                quote = None
            continue

        if char in {'"', "'"}:
            quote = char
            current.append(char)
            continue

        if char == "(":
            depth_paren += 1
        elif char == ")":
            depth_paren -= 1
        elif char == "[":
            depth_bracket += 1
        elif char == "]":
            depth_bracket -= 1
        elif char == "{":
            depth_brace += 1
        elif char == "}":
            depth_brace -= 1

        if (
            char == delimiter
            and depth_paren == 0
            and depth_bracket == 0
            and depth_brace == 0
        ):
            part = "".join(current).strip()
            if part:
                parts.append(part)
            current = []
            continue

        current.append(char)

    part = "".join(current).strip()
    if part:
        parts.append(part)
    return parts


def parse_scalar(value: str) -> object:
    stripped = value.strip()
    lowered = stripped.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in {"null", "none"}:
        return None
    try:
        if "." in stripped:
            return float(stripped)
        return int(stripped)
    except ValueError:
        pass
    try:
        return ast.literal_eval(stripped)
    except (ValueError, SyntaxError):
        return stripped


def parse_toolace_arguments(text: str) -> dict | None:
    if not text.strip():
        return {}

    arguments: dict[str, object] = {}
    for part in split_top_level(text):
        if "=" not in part:
            return None
        key, raw_value = part.split("=", 1)
        key = key.strip()
        if not key:
            return None
        arguments[key] = parse_scalar(raw_value)
    return arguments


def parse_toolace_tool_calls(content: str) -> list[dict]:
    stripped = content.strip()
    if not stripped.startswith("[") or not stripped.endswith("]"):
        return []
    inner = stripped[1:-1].strip()
    if not inner:
        return []

    raw_calls = []
    for chunk in split_top_level(inner):
        match = re.fullmatch(r"\s*([^()]+?)\s*\((.*)\)\s*", chunk, re.DOTALL)
        if match is None:
            return []
        name = match.group(1).strip()
        arguments = parse_toolace_arguments(match.group(2))
        if not name or arguments is None:
            return []
        raw_calls.append({"name": name, "arguments": arguments})
    return canonical_tool_calls(raw_calls)


def parse_toolace_tools(system_prompt: str) -> list[dict]:
    match = TOOLACE_SYSTEM_TOOLS_PATTERN.search(system_prompt)
    if match is None:
        return []
    raw_json = match.group(1).strip()
    start = raw_json.find("[")
    if start < 0:
        return []
    depth = 0
    end = -1
    quote: str | None = None
    escaped = False
    for index, char in enumerate(raw_json[start:], start=start):
        if quote is not None:
            if escaped:
                escaped = False
                continue
            if char == "\\":
                escaped = True
                continue
            if char == quote:
                quote = None
            continue
        if char in {'"', "'"}:
            quote = char
            continue
        if char == "[":
            depth += 1
        elif char == "]":
            depth -= 1
            if depth == 0:
                end = index
                break
    if end < 0:
        return []
    try:
        raw_tools = json.loads(raw_json[start : end + 1])
    except json.JSONDecodeError:
        return []
    if not isinstance(raw_tools, list):
        return []
    return normalize_tool_schemas(raw_tools)


def assistant_message_from_content(content: str, *, tool_parser) -> dict:
    tool_calls = tool_parser(content)
    if tool_calls:
        return {
            "role": "assistant",
            "content": None,
            "tool_calls": tool_calls,
        }
    return {
        "role": "assistant",
        "content": content.strip(),
    }


def contains_instruction_signal(text: str) -> bool:
    return any(pattern.search(text) for pattern in INSTRUCTION_PATTERNS)


def convert_instruction_row(row: dict) -> dict | None:
    messages = normalize_messages(row.get("messages") or [])
    if len(messages) < 2:
        return None
    user_text = "\n".join(
        str(message.get("content") or "")
        for message in messages
        if message.get("role") == "user"
    )
    if not contains_instruction_signal(user_text):
        return None
    if any(message.get("tool_calls") for message in messages):
        return None
    assistant_text = "\n".join(
        str(message.get("content") or "")
        for message in messages
        if message.get("role") == "assistant"
    ).strip()
    if not assistant_text:
        return None
    if serialized_length(messages) > 1800:
        return None
    return canonical_sft(
        messages,
        source="nvidia/Nemotron-Instruction-Following-Chat-v1",
        metadata={"capability_target": row.get("capability_target")},
    )


def convert_xlam_tool_use_row(row: dict) -> dict | None:
    messages = normalize_messages(row.get("messages") or [])
    if len(messages) < 2:
        return None
    if not any(message.get("tool_calls") for message in messages if message.get("role") == "assistant"):
        return None
    preferred_names = []
    for message in messages:
        if message.get("role") == "assistant":
            preferred_names.extend(extract_tool_names_from_message(message))
    user_text = "\n".join(
        str(message.get("content") or "")
        for message in messages
        if message.get("role") == "user"
    )
    tools = limit_tools_for_example(
        parse_tools(row.get("tools")),
        query_text=user_text,
        preferred_names=preferred_names,
    )
    if not tools:
        return None
    if serialized_length(messages) + serialized_length(tools) > 2200:
        return None
    return canonical_sft(
        messages,
        source="minpeter/xlam-function-calling-60k-parsed",
        tools=tools,
        metadata=row.get("extra") if isinstance(row.get("extra"), dict) else None,
    )


def convert_xlam_irrelevance_row(row: dict) -> dict | None:
    messages = normalize_messages(row.get("messages") or [])
    if len(messages) < 2:
        return None
    assistant_text = "\n".join(
        str(message.get("content") or "")
        for message in messages
        if message.get("role") == "assistant"
    ).strip()
    if not assistant_text:
        return None
    user_text = "\n".join(
        str(message.get("content") or "")
        for message in messages
        if message.get("role") == "user"
    )
    tools = limit_tools_for_example(parse_tools(row.get("tools")), query_text=user_text)
    if not tools:
        return None
    if serialized_length(messages) + serialized_length(tools) > 2200:
        return None
    return canonical_sft(
        messages,
        source="minpeter/xlam-irrelevance-7.5k-qwen2.5-72b-distill-parsed",
        tools=tools,
        metadata=row.get("extra") if isinstance(row.get("extra"), dict) else None,
    )


def convert_when2call_sft_row(row: dict) -> dict | None:
    raw_messages = row.get("messages")
    raw_tools = row.get("tools")
    if not isinstance(raw_messages, list) or len(raw_messages) < 2:
        return None
    if not isinstance(raw_tools, list) or not raw_tools:
        return None

    user = raw_messages[0]
    assistant = raw_messages[1]
    user_text = str(user.get("content", "")).strip()
    assistant_text = str(assistant.get("content", "")).strip()
    if not user_text or not assistant_text:
        return None

    assistant_message = assistant_message_from_content(assistant_text, tool_parser=parse_when2call_tool_calls)
    preferred_names = extract_tool_names_from_message(assistant_message)
    tools = limit_tools_for_example(raw_tools, query_text=user_text, preferred_names=preferred_names)
    if not tools:
        return None

    messages = [
        {
            "role": "system",
            "content": (
                "You are Fae. Use a tool only when one of the available tools is genuinely useful, "
                "ask a short clarification when required information is missing, and otherwise reply directly."
            ),
        },
        {"role": "user", "content": user_text},
        assistant_message,
    ]

    if serialized_length(messages) + serialized_length(tools) > MAX_TOOLING_EXAMPLE_CHARS:
        return None

    return canonical_sft(
        messages,
        source="nvidia/When2Call",
        tools=tools,
        metadata={"lane": "when2call_sft", "tool_count": len(tools)},
    )


def convert_when2call_pref_row(row: dict) -> dict | None:
    raw_messages = row.get("messages")
    chosen = row.get("chosen_response")
    rejected = row.get("rejected_response")
    raw_tools = row.get("tools")
    if not isinstance(raw_messages, list) or len(raw_messages) == 0:
        return None
    if not isinstance(chosen, dict) or not isinstance(rejected, dict):
        return None

    user_text = str(raw_messages[0].get("content", "")).strip()
    chosen_text = str(chosen.get("content", "")).strip()
    rejected_text = str(rejected.get("content", "")).strip()
    if not user_text or not chosen_text or not rejected_text or chosen_text == rejected_text:
        return None

    tools = normalize_tool_schemas(raw_tools or [])
    prompt = [
        {
            "role": "system",
            "content": (
                "You are Fae. Choose the better next assistant action for the user's request. "
                "Prefer using a tool only when it is warranted, and ask for clarification only when needed."
            ),
        },
        {"role": "user", "content": user_text},
    ]

    metadata = {"lane": "when2call_pref"}
    if tools:
        metadata["tool_count"] = len(tools)

    return canonical_dpo(
        prompt,
        [{"role": "assistant", "content": chosen_text}],
        [{"role": "assistant", "content": rejected_text}],
        source="nvidia/When2Call",
        metadata=metadata,
    )


def convert_toolace_row(row: dict) -> dict | None:
    system_prompt = str(row.get("system", "")).strip()
    conversations = row.get("conversations")
    if not system_prompt or not isinstance(conversations, list) or len(conversations) < 2:
        return None

    user_turn = conversations[0]
    assistant_turn = conversations[1]
    user_text = str(user_turn.get("value", "")).strip()
    assistant_text = str(assistant_turn.get("value", "")).strip()
    if not user_text or not assistant_text:
        return None

    assistant_message = assistant_message_from_content(assistant_text, tool_parser=parse_toolace_tool_calls)
    preferred_names = extract_tool_names_from_message(assistant_message)
    tools = limit_tools_for_example(
        parse_toolace_tools(system_prompt),
        query_text=user_text,
        preferred_names=preferred_names,
    )
    if not tools:
        return None

    messages = [
        {
            "role": "system",
            "content": (
                "You are Fae. Pick the most relevant tool call when one of the available tools fits, "
                "ask for missing required information when necessary, and say no tool fits when appropriate."
            ),
        },
        {"role": "user", "content": user_text},
        assistant_message,
    ]

    if serialized_length(messages) + serialized_length(tools) > MAX_TOOLING_EXAMPLE_CHARS:
        return None

    return canonical_sft(
        messages,
        source="Team-ACE/ToolACE",
        tools=tools,
        metadata={"lane": "toolace", "tool_count": len(tools)},
    )


def parse_profile_fields(markdown: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    current_key: str | None = None
    current_parts: list[str] = []

    def commit() -> None:
        nonlocal current_key, current_parts
        if current_key is None:
            return
        values = [part.strip() for part in current_parts if part.strip()]
        if not values:
            current_key = None
            current_parts = []
            return
        joined = "; ".join(values)
        if joined.lower() not in {"unknown", "unkown", "n/a", "none"}:
            fields[current_key] = joined
        current_key = None
        current_parts = []

    for line in markdown.splitlines():
        header = re.match(r"\s*\*\*(.+?)\:\*\*\s*(.*)\s*$", line)
        if header is not None:
            commit()
            current_key = header.group(1).strip().lower()
            initial_value = header.group(2).strip()
            current_parts = [initial_value] if initial_value else []
            continue

        bullet = re.match(r"\s*[-*]\s*(.+?)\s*$", line)
        if bullet is not None and current_key is not None:
            current_parts.append(bullet.group(1).strip())
            continue

        if not line.strip():
            commit()

    commit()
    return fields


def render_memory_actions(old_fields: dict[str, str], new_fields: dict[str, str]) -> str:
    actions: list[str] = []
    for raw_key, memory_key in MEMORY_FIELDS.items():
        new_value = new_fields.get(raw_key)
        if not new_value:
            continue
        old_value = old_fields.get(raw_key)
        if old_value:
            if old_value == new_value:
                continue
            actions.append(
                f"SUPERSEDE: {memory_key} = {truncate(new_value, 140)} (was {truncate(old_value, 80)})"
            )
        else:
            actions.append(f"STORE: {memory_key} = {truncate(new_value, 140)}")
    return "\n".join(actions)


def convert_user_profile_update_row(row: dict) -> dict | None:
    input_text = truncate(str(row.get("Input") or "").strip(), 1000)
    old_profile = str(row.get("Old_profile") or "").strip()
    update_profile = str(row.get("Update_profile") or "").strip()
    if not input_text or not update_profile:
        return None

    old_fields = parse_profile_fields(old_profile)
    new_fields = parse_profile_fields(update_profile)
    memory_lines = render_memory_actions(old_fields, new_fields)
    if not memory_lines:
        return None

    messages = [
        {
            "role": "system",
            "content": (
                "You are Fae. Update durable user memory from new evidence. "
                "Output one action per line using STORE: key = value or SUPERSEDE: key = value."
            ),
        },
        {
            "role": "user",
            "content": (
                f"Current remembered profile:\n{truncate(old_profile or '(empty)', 900)}\n\n"
                f"New profile evidence:\n{truncate(input_text, 1500)}\n\n"
                "Emit only the memory actions implied by the update."
            ),
        },
        {
            "role": "assistant",
            "content": memory_lines,
        },
    ]
    if serialized_length(messages) > 2000:
        return None
    return canonical_sft(
        messages,
        source="Nusrat1234/UserProfileUpdate",
        metadata={"field_count": len(memory_lines.splitlines())},
    )


def collect_streaming_rows(
    dataset_name: str,
    split: str,
    limit: int,
    converter,
    *,
    config: str | None = None,
) -> list[dict]:
    from datasets import load_dataset

    records: list[dict] = []
    dataset = load_dataset(dataset_name, config, split=split, streaming=True)
    skipped = 0
    for row in dataset:
        try:
            converted = converter(row)
        except Exception as exc:
            skipped += 1
            if skipped <= 5:
                print(f"WARNING: skipping malformed row from {dataset_name}/{split}: {exc}")
            continue
        if converted is None:
            continue
        records.append(converted)
        if len(records) >= limit:
            break
    if skipped:
        print(f"Skipped {skipped} malformed rows from {dataset_name}/{split}")
    return records


def collect_in_memory_rows(
    dataset_name: str,
    split: str,
    limit: int,
    converter,
    *,
    config: str | None = None,
) -> list[dict]:
    from datasets import load_dataset

    records: list[dict] = []
    dataset = load_dataset(dataset_name, config, split=split)
    skipped = 0
    for row in dataset:
        try:
            converted = converter(row)
        except Exception as exc:
            skipped += 1
            if skipped <= 5:
                print(f"WARNING: skipping malformed row from {dataset_name}/{split}: {exc}")
            continue
        if converted is None:
            continue
        records.append(converted)
        if len(records) >= limit:
            break
    if skipped:
        print(f"Skipped {skipped} malformed rows from {dataset_name}/{split}")
    return records


def import_instruction_lane(limit: int) -> dict[str, list[dict]]:
    return {
        "instruction_sft.jsonl": collect_streaming_rows(
            "nvidia/Nemotron-Instruction-Following-Chat-v1",
            "chat_if",
            limit,
            convert_instruction_row,
        )
    }


def import_tool_balance_lane(tool_use_limit: int, no_tool_limit: int) -> dict[str, list[dict]]:
    return {
        "tool_use_sft.jsonl": collect_streaming_rows(
            "minpeter/xlam-function-calling-60k-parsed",
            "train",
            tool_use_limit,
            convert_xlam_tool_use_row,
            config="xlam-function-calling-60k",
        ),
        "no_tool_sft.jsonl": collect_streaming_rows(
            "minpeter/xlam-irrelevance-7.5k-qwen2.5-72b-distill-parsed",
            "train",
            no_tool_limit,
            convert_xlam_irrelevance_row,
            config="distillation",
        ),
    }


def import_memory_lane(limit: int) -> dict[str, list[dict]]:
    return {
        "memory_profile_sft.jsonl": collect_in_memory_rows(
            "Nusrat1234/UserProfileUpdate",
            "train",
            limit,
            convert_user_profile_update_row,
        )
    }


def import_when2call_lane(sft_limit: int, pref_limit: int) -> dict[str, list[dict]]:
    return {
        "when2call_sft.jsonl": collect_in_memory_rows(
            "nvidia/When2Call",
            "train",
            sft_limit,
            convert_when2call_sft_row,
            config="train_sft",
        ),
        "when2call_pref.jsonl": collect_in_memory_rows(
            "nvidia/When2Call",
            "train",
            pref_limit,
            convert_when2call_pref_row,
            config="train_pref",
        ),
    }


def import_toolace_lane(limit: int) -> dict[str, list[dict]]:
    return {
        "toolace_sft.jsonl": collect_in_memory_rows(
            "Team-ACE/ToolACE",
            "train",
            limit,
            convert_toolace_row,
        )
    }


def import_user_profile_lane(limit: int) -> dict[str, list[dict]]:
    return {
        "user_profile_sft.jsonl": collect_in_memory_rows(
            "Nusrat1234/UserProfileUpdate",
            "train",
            limit,
            convert_user_profile_update_row,
        )
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--lane",
        choices=[
            "instruction",
            "tool-balance",
            "memory",
            "when2call",
            "toolace",
            "user-profile",
            "all",
        ],
        default="all",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("training/imports/hf-lanes"),
        help="Root directory for lane-specific canonical JSONL files.",
    )
    parser.add_argument("--instruction-limit", type=int, default=200)
    parser.add_argument("--tool-use-limit", type=int, default=250)
    parser.add_argument("--no-tool-limit", type=int, default=250)
    parser.add_argument("--memory-limit", type=int, default=300)
    parser.add_argument("--when2call-sft-limit", type=int, default=400)
    parser.add_argument("--when2call-pref-limit", type=int, default=250)
    parser.add_argument("--toolace-limit", type=int, default=400)
    parser.add_argument("--user-profile-limit", type=int, default=400)
    args = parser.parse_args()

    lane_builders = {
        "instruction": lambda: import_instruction_lane(args.instruction_limit),
        "tool-balance": lambda: import_tool_balance_lane(args.tool_use_limit, args.no_tool_limit),
        "memory": lambda: import_memory_lane(args.memory_limit),
        "when2call": lambda: import_when2call_lane(args.when2call_sft_limit, args.when2call_pref_limit),
        "toolace": lambda: import_toolace_lane(args.toolace_limit),
        "user-profile": lambda: import_user_profile_lane(args.user_profile_limit),
    }

    selected_lanes = list(lane_builders) if args.lane == "all" else [args.lane]
    manifest: dict[str, dict[str, int]] = {}

    for lane in selected_lanes:
        lane_dir = args.output_dir / lane
        lane_dir.mkdir(parents=True, exist_ok=True)
        lane_manifest: dict[str, int] = {}
        lane_records = lane_builders[lane]()
        for filename, records in lane_records.items():
            write_jsonl(lane_dir / filename, records)
            lane_manifest[filename] = len(records)
        manifest[lane] = lane_manifest

    manifest_path = args.output_dir / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    print(json.dumps(manifest, indent=2))
    print(f"Wrote manifest to {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
