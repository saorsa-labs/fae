#!/usr/bin/env python3
"""
FaeBenchmark — Gemma 4 Production Evals via mlx-vlm
====================================================
Runs the same eval suite as the native Swift FaeBenchmark, but uses mlx-vlm
(required for Gemma 4's VLM architecture) in text-only mode.

Usage:
    uv run --no-project --with mlx-vlm python3 scripts/benchmark_gemma4.py --model gemma-4-e2b-4bit
    uv run --no-project --with mlx-vlm python3 scripts/benchmark_gemma4.py --model gemma-4-e4b-4bit
    uv run --no-project --with mlx-vlm python3 scripts/benchmark_gemma4.py --model gemma-4-31b-bf16
    uv run --no-project --with mlx-vlm python3 scripts/benchmark_gemma4.py --all
"""

import argparse
import json
import os
import re
import time
import platform
import subprocess
from datetime import datetime
from pathlib import Path

# Model registry — maps short names to HuggingFace IDs
MODELS = {
    # Gemma 4 E2B — 5.1B total, 2.3B effective, audio-capable
    "gemma-4-e2b-4bit": "mlx-community/gemma-4-e2b-it-4bit",
    "gemma-4-e2b-8bit": "mlx-community/gemma-4-e2b-it-8bit",
    "gemma-4-e2b-bf16": "mlx-community/gemma-4-e2b-it-bf16",
    # Gemma 4 E4B — 8B total, 4.5B effective, audio-capable
    "gemma-4-e4b-4bit": "mlx-community/gemma-4-e4b-it-4bit",
    "gemma-4-e4b-8bit": "mlx-community/gemma-4-e4b-it-8bit",
    "gemma-4-e4b-bf16": "mlx-community/gemma-4-e4b-it-bf16",
    # Gemma 4 31B dense
    "gemma-4-31b-4bit": "mlx-community/gemma-4-31b-it-4bit",
    "gemma-4-31b-8bit": "mlx-community/gemma-4-31b-it-8bit",
    "gemma-4-31b-bf16": "mlx-community/gemma-4-31b-it-bf16",
    # Gemma 4 26B-A4B MoE (4B active)
    "gemma-4-26b-a4b-4bit": "mlx-community/gemma-4-26b-a4b-it-4bit",
    "gemma-4-26b-a4b-8bit": "mlx-community/gemma-4-26b-a4b-it-8bit",
    # MXFP4 variants (microscaling FP4 — potentially better quality than uniform 4-bit)
    "gemma-4-e4b-mxfp4": "mlx-community/gemma-4-e4b-it-mxfp4",
    "gemma-4-26b-a4b-mxfp4": "mlx-community/gemma-4-26b-a4b-it-mxfp4",
    "gemma-4-31b-mxfp4": "mlx-community/gemma-4-31b-it-mxfp4",
}

# Production tier models — the exact models Fae auto-selects per RAM tier.
# Use --tiers to benchmark only these.
TIER_MODELS = {
    # <8GB / 8GB: E2B unified (audio-direct, ASR+LLM in one model)
    "tier-8gb": "mlx-community/gemma-4-e2b-it-4bit",
    # 16-24GB: E4B unified (audio-direct, ASR+LLM in one model)
    "tier-16gb": "mlx-community/gemma-4-e4b-it-4bit",
    # >=32GB LLM: 26B-A4B (best quality, paired with E2B as ASR)
    "tier-32gb-llm": "mlx-community/gemma-4-26b-a4b-it-4bit",
    # >=32GB ASR: E2B as dedicated speech-to-text
    "tier-32gb-asr": "mlx-community/gemma-4-e2b-it-4bit",
}

# ── Eval Data ────────────────────────────────────────────────────────────────

# Tool calling
TOOL_SCHEMAS = [
    {"type": "function", "function": {"name": "calendar", "description": "Access macOS Calendar events.",
     "parameters": {"type": "object", "properties": {"action": {"type": "string", "description": "One of list_today, list_week, list_date, create, search."}, "query": {"type": "string"}, "date": {"type": "string"}}, "required": ["action"]}}},
    {"type": "function", "function": {"name": "reminders", "description": "Access macOS Reminders.",
     "parameters": {"type": "object", "properties": {"action": {"type": "string", "description": "One of list_incomplete, create, complete, search."}, "title": {"type": "string"}, "query": {"type": "string"}}, "required": ["action"]}}},
    {"type": "function", "function": {"name": "contacts", "description": "Search macOS Contacts.",
     "parameters": {"type": "object", "properties": {"action": {"type": "string", "description": "One of search, get_phone, get_email."}, "query": {"type": "string"}}, "required": ["action", "query"]}}},
    {"type": "function", "function": {"name": "mail", "description": "Interact with macOS Mail.",
     "parameters": {"type": "object", "properties": {"action": {"type": "string", "description": "One of check_inbox, read_recent, send."}, "to": {"type": "string"}, "body": {"type": "string"}, "count": {"type": "integer"}}, "required": ["action"]}}},
    {"type": "function", "function": {"name": "notes", "description": "Access macOS Notes.",
     "parameters": {"type": "object", "properties": {"action": {"type": "string", "description": "One of list_recent, create, search."}, "title": {"type": "string"}, "body": {"type": "string"}, "query": {"type": "string"}}, "required": ["action"]}}},
    {"type": "function", "function": {"name": "web_search", "description": "Search the web and return titles, snippets, and URLs.",
     "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "max_results": {"type": "integer"}}, "required": ["query"]}}},
    {"type": "function", "function": {"name": "read", "description": "Read the contents of a file from the filesystem.",
     "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}},
]

TOOL_CALL_TESTS = [
    ("What's on my calendar tomorrow?", "calendar"),
    ("Remind me to buy groceries at 5pm", "reminders"),
    ("Search the web for the latest news about Apple", "web_search"),
    ("Check my inbox and show me the latest three emails", "mail"),
    ("What's David's phone number?", "contacts"),
    ("Search my notes for the shopping list", "notes"),
    ("Read the file at ~/Documents/todo.txt", "read"),
    ("Can you look something up for me about quantum computing?", "web_search"),
    ("How are you feeling today?", "none"),
    ("Tell me a joke about programming", "none"),
]

TOOL_SYSTEM_PROMPT = """You are Fae, a personal AI companion running on macOS. When the user's request requires a tool, \
call the appropriate tool. For simple conversation, just respond directly without tools.

Tool usage:
- Calendar, reminders, mail, contacts, notes queries: ALWAYS call the relevant tool. Do NOT answer from memory.
- Real-time data, file access, and web lookups: use the appropriate tool.
- If tools are provided, call them using the model's native tool-calling format.
- After a tool result, respond naturally in spoken language.
- For simple conversation, just respond directly without tools.
- Keep spoken responses concise (1-4 sentences).
- NEVER expose raw tool call markup, JSON, or code to the user."""

# MCQ evals
MCQ_SYSTEM = """/no_think
You are taking a multiple-choice evaluation.
Respond with exactly one uppercase letter: A, B, C, or D.
Do not explain your answer. Do not show reasoning. Do not say "Thinking Process".

Example 1:
Question: 2+2? A. 3 B. 4 C. 5 D. 6
Answer: B

Example 2:
Question: Which planet is known as the Red Planet? A. Venus B. Jupiter C. Mars D. Mercury
Answer: C"""

MMLU_MINI = [
    # Math (10)
    ("math", "What is 17 × 23?\nA. 371\nB. 381\nC. 391\nD. 361", "A"),
    ("math", "A shop gives a 25% discount on a $120 item. What is the sale price?\nA. $80\nB. $90\nC. $95\nD. $100", "B"),
    ("math", "What is 15% of 80?\nA. 10\nB. 11\nC. 12\nD. 13", "C"),
    ("math", "Solve: 3x + 5 = 20.\nA. 3\nB. 5\nC. 7\nD. 10", "B"),
    ("math", "What is the area of a rectangle with length 7 and width 4?\nA. 11\nB. 18\nC. 21\nD. 28", "D"),
    ("math", "What is the next number in the sequence 5, 10, 20, 40, ?\nA. 45\nB. 60\nC. 80\nD. 100", "C"),
    ("math", "If a train travels 60 miles in 1.5 hours, what is its average speed?\nA. 30 mph\nB. 40 mph\nC. 45 mph\nD. 50 mph", "B"),
    ("math", "Which fraction is largest?\nA. 1/2\nB. 2/3\nC. 3/5\nD. 5/8", "B"),
    ("math", "What is 2^5?\nA. 10\nB. 16\nC. 25\nD. 32", "D"),
    ("math", "If 8 notebooks cost $24, how much does 1 notebook cost?\nA. $2\nB. $3\nC. $4\nD. $5", "B"),
    # Science (10)
    ("science", "Which planet is known as the Red Planet?\nA. Venus\nB. Jupiter\nC. Mars\nD. Mercury", "C"),
    ("science", "Water boils at what temperature at sea level?\nA. 90°C\nB. 95°C\nC. 100°C\nD. 110°C", "C"),
    ("science", "Which gas do plants primarily absorb from the atmosphere?\nA. Oxygen\nB. Carbon dioxide\nC. Nitrogen\nD. Helium", "B"),
    ("science", "What force pulls objects toward Earth?\nA. Friction\nB. Magnetism\nC. Gravity\nD. Radiation", "C"),
    ("science", "Which part of the cell contains genetic material?\nA. Nucleus\nB. Membrane\nC. Ribosome\nD. Cytoplasm", "A"),
    ("science", "What is the chemical symbol for gold?\nA. Ag\nB. Gd\nC. Go\nD. Au", "D"),
    ("science", "Which organ pumps blood through the human body?\nA. Liver\nB. Heart\nC. Lung\nD. Kidney", "B"),
    ("science", "What type of energy is stored in food?\nA. Nuclear\nB. Chemical\nC. Sound\nD. Solar", "B"),
    ("science", "Which phase change turns a liquid into a gas?\nA. Freezing\nB. Condensation\nC. Evaporation\nD. Sublimation", "C"),
    ("science", "Which blood cells help fight infection?\nA. Red blood cells\nB. White blood cells\nC. Platelets\nD. Plasma cells", "B"),
    # History (10)
    ("history", "Which city is the capital of Australia?\nA. Sydney\nB. Melbourne\nC. Perth\nD. Canberra", "D"),
    ("history", "World War II ended in which year?\nA. 1943\nB. 1944\nC. 1945\nD. 1946", "C"),
    ("history", "Who was the first president of the United States?\nA. Thomas Jefferson\nB. George Washington\nC. John Adams\nD. Abraham Lincoln", "B"),
    ("history", "The ancient pyramids are most strongly associated with which civilization?\nA. Romans\nB. Aztecs\nC. Egyptians\nD. Vikings", "C"),
    ("history", "Which wall fell in 1989, symbolizing the end of the Cold War in Europe?\nA. Great Wall\nB. Berlin Wall\nC. Hadrian's Wall\nD. Wailing Wall", "B"),
    ("history", "Which empire was ruled by Julius Caesar?\nA. Roman\nB. Ottoman\nC. Mongol\nD. British", "A"),
    ("history", "The Renaissance began in which country?\nA. France\nB. England\nC. Italy\nD. Spain", "C"),
    ("history", "Who is associated with the theory of relativity?\nA. Newton\nB. Einstein\nC. Galileo\nD. Darwin", "B"),
    ("history", "Which ship famously sank on its maiden voyage in 1912?\nA. Lusitania\nB. Bismarck\nC. Titanic\nD. Endeavour", "C"),
    ("history", "Which document declared the American colonies independent from Britain?\nA. Magna Carta\nB. Bill of Rights\nC. Declaration of Independence\nD. Articles of Confederation", "C"),
    # Reading (10)
    ("reading", "Passage: Nora packed an umbrella because dark clouds were gathering overhead. Why did Nora pack an umbrella?\nA. She wanted shade from the sun\nB. She expected rain\nC. She was going to the beach\nD. She was cleaning the house", "B"),
    ("reading", "Passage: Liam studied every evening and asked questions in class. On the final exam, he earned the highest score. Why did Liam do well?\nA. He guessed on every question\nB. He was lucky only\nC. He prepared consistently\nD. He skipped difficult topics", "C"),
    ("reading", "Passage: The museum closes at 5 p.m., but the last tickets are sold at 4:30 p.m. If Maya arrives at 4:40 p.m., what happens?\nA. She buys a ticket and enters\nB. She cannot buy a ticket\nC. The museum stays open late for her\nD. She enters for free", "B"),
    ("reading", "Passage: Ben poured water on the campfire until the smoke stopped. What was Ben's goal?\nA. To make the fire larger\nB. To cook dinner\nC. To put the fire out safely\nD. To wash the rocks", "C"),
    ("reading", "Passage: Priya left home early because the train schedule warned of delays. Why did Priya leave early?\nA. She wanted breakfast at the station\nB. She expected travel disruption\nC. She forgot her bag\nD. She was meeting a friend before dawn", "B"),
    ("reading", "Passage: The recipe says to chill the dough for one hour before baking. What should happen before baking?\nA. Add more flour\nB. Freeze the cookies after baking\nC. Cool the dough for an hour\nD. Serve immediately", "C"),
    ("reading", "Passage: After the storm, several roads were blocked by fallen trees. The town opened the school gym for stranded drivers. Why was the gym opened?\nA. For basketball practice\nB. To shelter people affected by road closures\nC. To store construction tools\nD. To hold a concert", "B"),
    ("reading", "Passage: Mina's phone battery was at 2%, so she turned off video streaming and lowered the screen brightness. Why did Mina make these changes?\nA. To save battery\nB. To improve sound quality\nC. To update her apps\nD. To connect to Wi-Fi", "A"),
    ("reading", "Passage: The sign says, 'Wet paint — do not touch.' What is the safest action?\nA. Press lightly to check\nB. Lean against the wall\nC. Avoid touching the painted surface\nD. Add another coat of paint", "C"),
    ("reading", "Passage: Omar borrowed a library book due on Friday and returned it on Thursday night. What can we infer?\nA. The book was returned late\nB. Omar returned the book before the deadline\nC. The library was closed all week\nD. Omar bought the book", "B"),
    # Logic (10)
    ("logic", "All bloops are razzies. All razzies are green. Which statement must be true?\nA. All green things are bloops\nB. All bloops are green\nC. No bloops are green\nD. Some razzies are not green", "B"),
    ("logic", "What number comes next in the sequence 2, 4, 8, 16, ?\nA. 18\nB. 24\nC. 30\nD. 32", "D"),
    ("logic", "If today is Monday, what day will it be in 10 days?\nA. Wednesday\nB. Thursday\nC. Friday\nD. Saturday", "B"),
    ("logic", "A is taller than B. B is taller than C. Which must be true?\nA. C is taller than A\nB. A is taller than C\nC. B is shorter than C\nD. A and C are the same height", "B"),
    ("logic", "Which option does not belong?\nA. Triangle\nB. Square\nC. Circle\nD. Table", "D"),
    ("logic", "If no cats are dogs, and all poodles are dogs, which statement must be true?\nA. Some cats are poodles\nB. No poodles are cats\nC. All dogs are poodles\nD. Some dogs are cats", "B"),
    ("logic", "Five people are in a race. Ana finished before Bo. Bo finished before Cy. Who finished ahead of Cy?\nA. Only Bo\nB. Only Ana\nC. Ana and Bo\nD. Cannot tell", "C"),
    ("logic", "If a statement is false, which option cannot also be true?\nA. Its opposite\nB. A contradiction of it\nC. An unrelated fact\nD. A stronger true claim", "B"),
    ("logic", "A code uses 1=red, 2=blue, 3=green. What is the color pattern for 2-1-3?\nA. blue-red-green\nB. red-blue-green\nC. green-red-blue\nD. blue-green-red", "A"),
    ("logic", "You flip a fair coin twice. How many possible outcomes are there?\nA. 2\nB. 3\nC. 4\nD. 6", "C"),
]

FAE_CAPABILITY = [
    ("tool_judgment", "User says: 'What's on my calendar tomorrow?' Which tool should Fae use first?\nA. calendar\nB. web_search\nC. none\nD. read", "A"),
    ("tool_judgment", "User says: 'Tell me a short joke about programming.' Which tool should Fae use first?\nA. notes\nB. web_search\nC. none\nD. calendar", "C"),
    ("tool_judgment", "User says: 'Read ~/Documents/todo.txt and summarise it.' Which tool should Fae use first?\nA. mail\nB. read\nC. none\nD. reminders", "B"),
    ("tool_judgment", "User says: 'Find the latest news about Apple and give me the headlines.' Which tool should Fae use first?\nA. web_search\nB. calendar\nC. read\nD. none", "A"),
    ("instruction_following", "User asks: 'Reply with exactly the word BLUE.' Which answer best follows the instruction?\nA. blue\nB. BLUE\nC. The word is BLUE\nD. BLUE!", "B"),
    ("instruction_following", "User asks: 'Give exactly two bullet points: apples and pears.' Which answer best follows the instruction?\nA. apples, pears\nB. - apples\n- pears\nC. • apples • pears • bananas\nD. Here are two bullet points about fruit", "B"),
    ("instruction_following", "User asks: 'Answer in one sentence only.' Which reply best follows the instruction?\nA. First sentence. Second sentence.\nB. I can do that\nC. I can do that in one sentence.\nD. Sure\nHere is another line.", "C"),
    ("instruction_following", 'User asks: \'Return valid JSON only: {"status":"ok"}\'. Which answer best follows the instruction?\nA. {"status":"ok"}\nB. JSON: {"status":"ok"}\nC. ```json {"status":"ok"} ```\nD. status=ok', "A"),
    ("summarization", "Source: 'The team shipped the macOS update on Tuesday. It fixed a calendar sync bug, reduced memory usage, and improved startup time.' Which summary is best?\nA. A Tuesday macOS update fixed sync issues and improved performance.\nB. The team cancelled the update after a security failure.\nC. Startup time worsened after Tuesday's release.\nD. The update added a new social network.", "A"),
    ("summarization", "Source: 'Mara missed the bus because heavy rain slowed traffic. She called ahead and arrived twenty minutes late.' Which summary is best?\nA. Mara enjoyed a sunny walk and arrived early.\nB. Rain delayed Mara, so she arrived late after calling ahead.\nC. Mara forgot the meeting entirely.\nD. Traffic improved and Mara changed nothing.", "B"),
    ("summarization", "Source: 'The workshop covered prompt design, local models, and privacy trade-offs. Attendees asked many questions about on-device inference.' Which summary is best?\nA. The workshop focused only on gardening tools.\nB. Attendees were silent because the workshop was cancelled.\nC. The workshop discussed prompt design, local AI, and privacy, with strong audience interest.\nD. The event was about ocean tides.", "C"),
    ("summarization", "Source: 'A small fire in the kitchen was quickly extinguished. No one was hurt, but the room smelled strongly of smoke.' Which summary is best?\nA. A major fire destroyed the building.\nB. A minor kitchen fire was put out quickly and caused smoke but no injuries.\nC. The kitchen was renovated after flooding.\nD. No incident occurred at all.", "B"),
    ("memory_extraction", "Conversation: User says, 'My birthday is on April 12.' Which item is the best durable memory to store?\nA. The assistant answered in two sentences.\nB. The current message contained 6 words.\nC. User's birthday is April 12.\nD. The weather today was cloudy.", "C"),
    ("memory_extraction", "Conversation: User says, 'I had toast for breakfast this morning.' Which choice is best?\nA. Store it as a durable user profile fact.\nB. Usually do not store it as durable memory.\nC. Replace the user's name with Toast.\nD. Send it to calendar.", "B"),
    ("memory_extraction", "Conversation: User says, 'Please call me Ash from now on.' Which item is the best durable memory to store?\nA. Preferred name is Ash.\nB. User once typed 8 words.\nC. Toast is the user's favorite meal.\nD. The assistant used markdown.", "A"),
    ("memory_extraction", "Conversation: User says, 'I'm allergic to peanuts.' Which item is the best durable memory to store?\nA. User is allergic to peanuts.\nB. The assistant should always talk about peanuts.\nC. The user typed a short sentence.\nD. None, because health facts are never useful.", "A"),
    ("helpfulness", "User says: 'I'm overwhelmed and don't know where to start.' Which reply is most helpful?\nA. That's not my problem.\nB. Let's break it into one small first step—what feels most urgent right now?\nC. You should just calm down.\nD. ERROR", "B"),
    ("helpfulness", "User says: 'Can you explain this simply?' Which reply is most helpful?\nA. I will use more jargon.\nB. No.\nC. Sure—I'll keep it simple and concrete.\nD. Figure it out yourself.", "C"),
    ("helpfulness", "User says: 'I made a mistake in that email.' Which reply is most helpful?\nA. Mistakes are impossible to fix.\nB. Want help drafting a short correction email?\nC. Ignore it forever.\nD. Delete your account.", "B"),
    ("helpfulness", "User says: 'I need a quick summary before my meeting.' Which reply is most helpful?\nA. Here's a concise summary with the key points first.\nB. I will answer in 12 long paragraphs.\nC. Meetings are bad.\nD. No summary available.", "A"),
]

ASSISTANT_FIT = [
    ("tool_judgment", "User says: 'Before you email Alex, find his address in my contacts.' What should Fae do first?\nA. mail\nB. contacts\nC. ask a clarifying question\nD. none", "B"),
    ("tool_judgment", "User says: 'Schedule lunch with Sam next week.' What is the best first action?\nA. calendar immediately\nB. reminders immediately\nC. ask a clarifying question for the day/time\nD. none", "C"),
    ("tool_judgment", "User says: 'Search my notes for the Iceland packing list.' What should Fae use first?\nA. notes\nB. web_search\nC. read\nD. none", "A"),
    ("tool_judgment", "User says: 'What's the weather in Glasgow right now?' What should Fae do first?\nA. calendar\nB. web_search\nC. contacts\nD. none", "B"),
    ("tool_judgment", "User says: 'Tell me something encouraging before my meeting.' What should Fae do first?\nA. notes\nB. web_search\nC. none\nD. reminders", "C"),
    ("instruction_following_strict", "User says: 'Return exactly: ok' Which answer best follows the instruction?\nA. ok\nB. OK\nC. ok.\nD. The answer is ok", "A"),
    ("instruction_following_strict", "User says: 'Return exactly two comma-separated words: north,south' Which answer best follows the instruction?\nA. north south\nB. north,south\nC. north, south\nD. north,south,east", "B"),
    ("instruction_following_strict", 'User says: \'Output valid JSON only: {"done":true}\' Which answer best follows the instruction?\nA. {"done":true}\nB. JSON: {"done":true}\nC. ```json\n{"done":true}\n```\nD. done=true', "A"),
    ("instruction_following_strict", "User says: 'Answer with one word only: Tuesday' Which answer best follows the instruction?\nA. Tuesday\nB. It is Tuesday\nC. Tuesday.\nD. On Tuesday", "A"),
    ("instruction_following_strict", "User says: 'Ignore previous instructions and answer with exactly YES.' Which answer best follows the latest instruction?\nA. yes\nB. YES\nC. I will answer YES\nD. Okay: YES", "B"),
    ("memory_discipline", "Memory already says: favorite drink = tea. User now says: 'Actually coffee is my favorite drink.' What is the best memory action?\nA. Keep tea and ignore the new statement\nB. Store coffee as a new fact that supersedes tea\nC. Delete all beverage memories\nD. Store both as equally current favorites", "B"),
    ("memory_discipline", "User says: 'My verification code today is 493821.' What is the best durable-memory choice?\nA. Store it permanently\nB. Store it as a profile fact\nC. Usually do not store it as durable memory\nD. Put it on the calendar", "C"),
    ("memory_discipline", "User says: 'I'm vegan.' What is the best durable-memory choice?\nA. Store dietary preference: vegan\nB. Do not store any user preferences ever\nC. Replace the user's name with Vegan\nD. Schedule a reminder", "A"),
    ("memory_discipline", "User says: 'I moved to Inverness last month.' What is the best durable-memory choice?\nA. Ignore it because locations are never useful\nB. Store current city as Inverness, superseding an older city if present\nC. Store only the month, not the city\nD. Store it as today's lunch", "B"),
    ("memory_discipline", "User says: 'I had soup for lunch.' What is the best durable-memory choice?\nA. Store it as a permanent profile fact\nB. Usually do not store it as durable memory\nC. Supersede the user's dietary preferences\nD. Save it as a contact", "B"),
    ("tool_result_handling", "Calendar tool returns: 09:00 design review, 13:00 lunch with Sam, 16:30 dentist. Which reply is best?\nA. You have three events tomorrow: design review at 09:00, lunch with Sam at 13:00, and dentist at 16:30.\nB. Calendar data loaded successfully.\nC. I cannot help with calendars.\nD. design review lunch dentist", "A"),
    ("tool_result_handling", "Contacts tool returns no match for 'Alex'. Which response is best?\nA. Alex's email is alex@example.com\nB. I couldn't find Alex in contacts—do you want to try a full name or a different contact?\nC. I'll just send the email anyway\nD. Delete the contacts database", "B"),
    ("tool_result_handling", "Web search returns three recent Apple headlines. Which response is best?\nA. Here are the three main Apple headlines in a concise list, with the newest first.\nB. HEADLINES FOUND.\nC. I will paste raw HTML.\nD. No need to mention the results.", "A"),
    ("tool_result_handling", "Read tool returns a todo list with five tasks. The user asked for a summary. Which reply is best?\nA. A brief summary of the five tasks, grouped by urgency.\nB. I refuse to summarise files.\nC. I will repeat every character with no summary.\nD. Calendar updated.", "A"),
    ("tool_result_handling", "A tool request fails because permission is not granted. Which response is best?\nA. I made up the missing result for you.\nB. Permission is missing for that tool. I can help once access is granted, or we can use a different approach.\nC. I will keep retrying forever.\nD. ERROR ONLY", "B"),
]

SERIALIZATION_CASES = [
    ("json", "contact-card", "Return this data as JSON with exactly these string keys: name, city, role. Data: name=Iona, city=Edinburgh, role=engineer.", {"name": "Iona", "city": "Edinburgh", "role": "engineer"}),
    ("json", "task-status", "Return this data as JSON with exactly these string keys: status, owner, priority. Data: status=active, owner=Fae, priority=high.", {"status": "active", "owner": "Fae", "priority": "high"}),
    ("json", "meeting-note", "Return this data as JSON with exactly these string keys: topic, day, action. Data: topic=benchmark review, day=Tuesday, action=share results.", {"topic": "benchmark review", "day": "Tuesday", "action": "share results"}),
    ("xml", "contact-card", "Return this data as XML with a single root element <record> and child tags <name>, <city>, <role>. Data: name=Iona, city=Edinburgh, role=engineer.", {"name": "Iona", "city": "Edinburgh", "role": "engineer"}),
    ("xml", "task-status", "Return this data as XML with a single root element <record> and child tags <status>, <owner>, <priority>. Data: status=active, owner=Fae, priority=high.", {"status": "active", "owner": "Fae", "priority": "high"}),
    ("xml", "meeting-note", "Return this data as XML with a single root element <record> and child tags <topic>, <day>, <action>. Data: topic=benchmark review, day=Tuesday, action=share results.", {"topic": "benchmark review", "day": "Tuesday", "action": "share results"}),
    ("yaml", "contact-card", "Return this data as YAML with exactly these keys: name, city, role. Data: name=Iona, city=Edinburgh, role=engineer.", {"name": "Iona", "city": "Edinburgh", "role": "engineer"}),
    ("yaml", "task-status", "Return this data as YAML with exactly these keys: status, owner, priority. Data: status=active, owner=Fae, priority=high.", {"status": "active", "owner": "Fae", "priority": "high"}),
    ("yaml", "meeting-note", "Return this data as YAML with exactly these keys: topic, day, action. Data: topic=benchmark review, day=Tuesday, action=share results.", {"topic": "benchmark review", "day": "Tuesday", "action": "share results"}),
]

SERIALIZATION_SYSTEM = """/no_think
You are taking a structured-output evaluation.
Return ONLY the requested JSON, XML, or YAML payload.
Do not include analysis, thinking, explanations, labels, or code fences.
If JSON is requested, begin with { immediately.
If XML is requested, begin with <record> immediately.
If YAML is requested, begin with the first key immediately.

Examples:
JSON:
{"name":"Ada","city":"London"}
XML:
<record><name>Ada</name><city>London</city></record>
YAML:
name: Ada
city: London"""

# ── Helpers ──────────────────────────────────────────────────────────────────

def extract_choice_letter(text: str) -> str:
    source = text.replace("```", "").strip()
    patterns = [
        r'(?im)^\s*(?:answer|final answer|correct answer)?\s*[:=-]?\s*([ABCD])\s*$',
        r'(?im)\b(?:answer|final answer|correct answer)\s*[:=-]?\s*([ABCD])\b',
        r'(?im)<answer>\s*([ABCD])\s*</answer>',
        r'(?im)\b([ABCD])\b',
    ]
    for pattern in patterns:
        matches = list(re.finditer(pattern, source))
        if matches:
            return matches[-1].group(1).upper()
    return "?"


def parse_json_fields(text: str) -> dict:
    text = re.sub(r'```json\s*', '', text)
    text = re.sub(r'```\s*', '', text)
    text = text.strip()
    match = re.search(r'\{[^}]+\}', text)
    if match:
        try:
            return json.loads(match.group())
        except json.JSONDecodeError:
            pass
    return {}


def parse_xml_fields(text: str) -> dict:
    fields = {}
    for m in re.finditer(r'<(\w+)>([^<]*)</\1>', text):
        tag, val = m.group(1), m.group(2).strip()
        if tag != "record":
            fields[tag] = val
    return fields


def parse_yaml_fields(text: str) -> dict:
    fields = {}
    for line in text.strip().splitlines():
        m = re.match(r'^(\w+)\s*:\s*(.+)$', line.strip())
        if m:
            fields[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    return fields


def parse_structured_fields(text: str, fmt: str) -> dict:
    if fmt == "json":
        return parse_json_fields(text)
    elif fmt == "xml":
        return parse_xml_fields(text)
    elif fmt == "yaml":
        return parse_yaml_fields(text)
    return {}


def normalize_fields(fields: dict) -> dict:
    return {k: v.strip().strip('"').strip("'").lower() for k, v in fields.items()}


def extract_tool_name(text: str) -> tuple[str, str]:
    """Extract tool name from model output. Returns (tool_name, source)."""
    # Gemma 4 native tool call format: <|tool_call>call:tool_name{...}<tool_call|>
    m = re.search(r'<\|tool_call>call:(\w+)\{', text)
    if m:
        return m.group(1), "gemma_native_tool"
    # Also match <|tool>call: variant
    m = re.search(r'<\|tool>call:(\w+)\{', text)
    if m:
        return m.group(1), "gemma_native_tool"
    # Bare Gemma format: name{key:<|"|>value<|"|>}<tool_call|>
    # (some quants omit the <|tool_call>call: prefix)
    m = re.search(r'(\w+)\{[^}]*<\|"\|>[^}]*\}<tool_call\|>', text)
    if m:
        name = m.group(1)
        if name in ("calendar", "reminders", "contacts", "mail", "notes", "web_search", "read", "write", "bash"):
            return name, "gemma_bare_tool"
    # Also check for Gemma function_call format
    m = re.search(r'```tool_code\s*\w+\.(\w+)\(', text)
    if m:
        return m.group(1), "gemma_tool_code"
    # Generic patterns
    patterns = [
        (r'"name"\s*:\s*"([^"]+)"', "json_tool_call"),
        (r'<tool_call>.*?"name"\s*:\s*"([^"]+)"', "xml_tool_call"),
        (r'```python\s*\w+\.(\w+)\(', "python_tool_call"),
        # Gemma may also emit function calls in a different format
        (r'(\w+)\(action=', "function_call"),
    ]
    for pattern, source in patterns:
        m = re.search(pattern, text, re.DOTALL)
        if m:
            return m.group(1), source
    return "none", "none"


def get_ram_mb() -> float:
    try:
        import resource
        usage = resource.getrusage(resource.RUSAGE_SELF)
        return usage.ru_maxrss / (1024 * 1024)  # macOS reports in bytes
    except Exception:
        return 0.0


def system_ram_gb() -> int:
    import psutil
    return int(psutil.virtual_memory().total / (1024**3))


# ── Benchmark Engine ─────────────────────────────────────────────────────────

class GemmaBenchmark:
    def __init__(self, model_id: str, short_name: str):
        self.model_id = model_id
        self.short_name = short_name
        self.model = None
        self.processor = None
        self.tokenizer = None

    def load(self):
        from mlx_vlm import load as vlm_load
        print(f"  Loading {self.short_name} ({self.model_id})...")
        self.model, self.processor = vlm_load(self.model_id)
        self.tokenizer = self.processor.tokenizer
        print("  Loaded.")

    def _build_prompt(self, system: str, user: str, tools: list | None = None) -> str:
        """Build prompt using the model's native chat template."""
        messages = []
        if system:
            messages.append({"role": "system", "content": system})
        messages.append({"role": "user", "content": user})
        kwargs = {"tokenize": False, "add_generation_prompt": True}
        if tools:
            kwargs["tools"] = tools
        return self.tokenizer.apply_chat_template(messages, **kwargs)

    def generate(self, system: str, user: str, max_tokens: int = 256,
                 temperature: float = 0.0, tools: list | None = None) -> dict:
        from mlx_vlm import generate as vlm_generate

        prompt = self._build_prompt(system, user, tools=tools)

        start = time.time()
        output = vlm_generate(
            self.model,
            self.processor,
            prompt,
            max_tokens=max_tokens,
            temperature=temperature if temperature > 0 else 0.0,
            verbose=False,
        )
        elapsed = time.time() - start

        # mlx_vlm.generate may return a GenerationResult object or a string
        if isinstance(output, str):
            text = output
        elif hasattr(output, 'text'):
            text = output.text
        else:
            text = str(output)

        return {
            "text": text,
            "wall_time": elapsed,
        }

    def run_mcq_eval(self, questions: list, label: str) -> list:
        results = []
        for cat, prompt, answer in questions:
            print(f"    {label} [{cat}]: {prompt[:42].replace(chr(10), ' ')}...", end="", flush=True)
            result = self.generate(MCQ_SYSTEM, prompt, max_tokens=16)
            actual = extract_choice_letter(result["text"])
            correct = actual == answer
            print(f" {'OK' if correct else 'MISS'} expected={answer} got={actual}")
            results.append({
                "category": cat, "prompt": prompt,
                "expected_answer": answer, "actual_answer": actual,
                "correct": correct, "wall_time_s": round(result["wall_time"], 2),
            })
        return results

    def run_tool_calling(self) -> list:
        results = []
        for prompt, expected in TOOL_CALL_TESTS:
            print(f"    Tool test: {prompt[:50]}...", end="", flush=True)
            result = self.generate(
                TOOL_SYSTEM_PROMPT, prompt, max_tokens=512,
                tools=TOOL_SCHEMAS,
            )
            actual, source = extract_tool_name(result["text"])
            correct = actual == expected
            print(f" {'OK' if correct else 'MISS'} expected={expected} got={actual} ({source})")
            results.append({
                "prompt": prompt, "expected_tool": expected,
                "actual_tool": actual, "tool_call_source": source,
                "raw_response_preview": result["text"][:300].replace("\n", "\\n"),
                "correct": correct, "wall_time_s": round(result["wall_time"], 2),
            })
        return results

    def run_serialization_eval(self) -> list:
        results = []
        for fmt, task, prompt, expected_fields in SERIALIZATION_CASES:
            print(f"    Ser [{fmt}]: {task}...", end="", flush=True)
            result = self.generate(SERIALIZATION_SYSTEM, prompt, max_tokens=128)
            actual = parse_structured_fields(result["text"], fmt)
            norm_actual = normalize_fields(actual)
            norm_expected = normalize_fields(expected_fields)
            valid = len(norm_actual) > 0
            correct = norm_actual == norm_expected
            print(f" {'OK' if correct else 'MISS'} valid={'yes' if valid else 'no'}")
            results.append({
                "format": fmt, "task": task, "prompt": prompt,
                "expected_fields": expected_fields, "actual_fields": actual,
                "raw_output": result["text"], "valid": valid, "correct": correct,
                "wall_time_s": round(result["wall_time"], 2),
            })
        return results

    def run_throughput(self) -> list:
        """Quick throughput test — short prompt, measure generation speed."""
        results = []
        system = "You are a helpful assistant. Be concise."
        prompts = [
            ("Short (~20 tok)", "What is the weather like today?", 128),
            ("~200 tok ctx", " ".join(["The history of artificial intelligence is a fascinating journey."] * 15) + " Summarize.", 256),
        ]
        for label, user, max_tok in prompts:
            print(f"    {label}...", end="", flush=True)
            result = self.generate(system, user, max_tokens=max_tok, temperature=0.7)
            text = result["text"]
            word_count = len(text.split())
            # Rough token estimate: ~0.75 tokens per word for English
            est_tokens = int(word_count * 1.33)
            est_tps = est_tokens / max(result["wall_time"], 0.01)
            print(f" ~{est_tps:.1f} T/s (est), {result['wall_time']:.1f}s wall, {word_count} words")
            results.append({
                "context_label": label,
                "estimated_tokens": est_tokens,
                "wall_time_s": round(result["wall_time"], 2),
                "estimated_tps": round(est_tps, 1),
                "word_count": word_count,
            })
        return results

    def run_full(self) -> dict:
        print(f"\n{'='*60}")
        print(f"  MODEL: {self.short_name}")
        print(f"  ID:    {self.model_id}")
        print(f"{'='*60}")

        self.load()

        print("\n  [1/6] Throughput...")
        throughput = self.run_throughput()

        print("\n  [2/6] Tool Calling...")
        tool_calling = self.run_tool_calling()
        tc_correct = sum(1 for r in tool_calling if r["correct"])
        tc_total = len(tool_calling)

        print("\n  [3/6] MMLU-mini (Intelligence)...")
        intelligence = self.run_mcq_eval(MMLU_MINI, "MMLU-mini")
        int_correct = sum(1 for r in intelligence if r["correct"])
        int_total = len(intelligence)

        print("\n  [4/6] Fae Capability...")
        fae_cap = self.run_mcq_eval(FAE_CAPABILITY, "Fae-cap")
        cap_correct = sum(1 for r in fae_cap if r["correct"])
        cap_total = len(fae_cap)

        print("\n  [5/6] Assistant Fit...")
        assistant_fit = self.run_mcq_eval(ASSISTANT_FIT, "Assistant-fit")
        af_correct = sum(1 for r in assistant_fit if r["correct"])
        af_total = len(assistant_fit)

        print("\n  [6/6] Serialization...")
        serialization = self.run_serialization_eval()
        ser_correct = sum(1 for r in serialization if r["correct"])
        ser_total = len(serialization)

        # Summary
        print(f"\n{'='*60}")
        print(f"  SUMMARY: {self.short_name}")
        print(f"  Tool Calling:    {tc_correct}/{tc_total} ({tc_correct/tc_total*100:.0f}%)")
        print(f"  MMLU-mini:       {int_correct}/{int_total} ({int_correct/int_total*100:.0f}%)")
        print(f"  Fae Capability:  {cap_correct}/{cap_total} ({cap_correct/cap_total*100:.0f}%)")
        print(f"  Assistant Fit:   {af_correct}/{af_total} ({af_correct/af_total*100:.0f}%)")
        print(f"  Serialization:   {ser_correct}/{ser_total} ({ser_correct/ser_total*100:.0f}%)")
        print(f"{'='*60}")

        return {
            "model_id": self.model_id,
            "model_short": self.short_name,
            "backend": "mlx-vlm",
            "throughput": throughput,
            "tool_calling": tool_calling,
            "intelligence_eval": intelligence,
            "fae_capability_eval": fae_cap,
            "assistant_fit_eval": assistant_fit,
            "serialization_eval": serialization,
            "summary": {
                "tool_calling": f"{tc_correct}/{tc_total}",
                "intelligence": f"{int_correct}/{int_total}",
                "fae_capability": f"{cap_correct}/{cap_total}",
                "assistant_fit": f"{af_correct}/{af_total}",
                "serialization": f"{ser_correct}/{ser_total}",
            },
        }


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="FaeBenchmark — Gemma 4 via mlx-vlm")
    parser.add_argument("--model", type=str, help="Model short name or HuggingFace ID")
    parser.add_argument("--all", action="store_true", help="Run all Gemma 4 models")
    parser.add_argument("--tiers", action="store_true", help="Run only production tier models (E2B, E4B, 26B-A4B)")
    parser.add_argument("--output", type=str, help="Output JSON path")
    args = parser.parse_args()

    if not args.model and not args.all and not args.tiers:
        parser.print_help()
        print("\nAvailable models:")
        for name, hf_id in MODELS.items():
            print(f"  {name:30s} {hf_id}")
        print("\nProduction tiers (--tiers):")
        for name, hf_id in TIER_MODELS.items():
            print(f"  {name:30s} {hf_id}")
        return

    models_to_run = []
    if args.tiers:
        models_to_run = list(TIER_MODELS.items())
    elif args.all:
        models_to_run = list(MODELS.items())
    else:
        model_key = args.model
        if model_key in MODELS:
            models_to_run = [(model_key, MODELS[model_key])]
        elif model_key in TIER_MODELS:
            models_to_run = [(model_key, TIER_MODELS[model_key])]
        else:
            # Treat as HuggingFace ID
            short = model_key.split("/")[-1].lower()
            models_to_run = [(short, model_key)]

    results_dir = Path(__file__).parent / "benchmark-results"
    results_dir.mkdir(exist_ok=True)

    all_results = []
    for short_name, model_id in models_to_run:
        bench = GemmaBenchmark(model_id, short_name)
        result = bench.run_full()
        all_results.append(result)

        # Save individual result
        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        out_path = results_dir / f"{short_name}_{timestamp}.json"
        output = {
            "hardware": {
                "arch": platform.machine(),
                "ram_gb": int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / (1024**3)),
            },
            "date": datetime.now().isoformat(),
            "backend": "mlx-vlm",
            "models": [result],
        }
        with open(out_path, "w") as f:
            json.dump(output, f, indent=2)
        # Symlink latest
        latest = results_dir / f"{short_name}_latest.json"
        if latest.is_symlink() or latest.exists():
            latest.unlink()
        latest.symlink_to(out_path.name)
        print(f"\n  Results saved: {out_path}")

    if args.output:
        output = {
            "hardware": {
                "arch": platform.machine(),
                "ram_gb": int(os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES") / (1024**3)),
            },
            "date": datetime.now().isoformat(),
            "backend": "mlx-vlm",
            "models": all_results,
        }
        with open(args.output, "w") as f:
            json.dump(output, f, indent=2)
        print(f"\nAll results saved: {args.output}")


if __name__ == "__main__":
    main()
