"""Tool calling evaluation runner — inspired by ToolCall-15 methodology."""

from __future__ import annotations

from schemas import Dimension
from runners.base import BaseRunner


# Fae's 7 core tool schemas in OpenAI function calling format
FAE_TOOL_SCHEMAS = [
    {
        "type": "function",
        "function": {
            "name": "calendar",
            "description": "Read or create calendar events. Use for scheduling queries.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["list", "create", "search"]},
                    "range": {"type": "string", "description": "Time range (e.g. 'tomorrow', 'next week')"},
                    "title": {"type": "string"},
                    "date": {"type": "string"},
                    "time": {"type": "string"},
                },
                "required": ["action"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "reminders",
            "description": "Create, list, or complete reminders.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["create", "list", "complete"]},
                    "title": {"type": "string"},
                    "due": {"type": "string"},
                },
                "required": ["action"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "contacts",
            "description": "Search contacts by name.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Name to search for"},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "mail",
            "description": "Read, search, or send email.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["inbox", "search", "send"]},
                    "query": {"type": "string"},
                    "limit": {"type": "integer"},
                    "to": {"type": "string"},
                    "subject": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["action"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "notes",
            "description": "Search or create Apple Notes.",
            "parameters": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["search", "create"]},
                    "query": {"type": "string"},
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                },
                "required": ["action"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web for current information.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                },
                "required": ["query"],
                "additionalProperties": False,
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "read",
            "description": "Read a file from the filesystem.",
            "parameters": {
                "type": "object",
                "properties": {
                    "path": {"type": "string", "description": "File path to read"},
                },
                "required": ["path"],
                "additionalProperties": False,
            },
        },
    },
]


class ToolCallingRunner(BaseRunner):
    dimension = Dimension.tool_calling
