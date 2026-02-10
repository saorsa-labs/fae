# Pi Coding Agent

You have access to a coding agent called Pi via the `pi_delegate` tool.

## When to use

Use `pi_delegate` when the user asks you to:
- Write, modify, or refactor code in any language
- Edit configuration files (TOML, YAML, JSON, etc.)
- Run shell commands, build projects, or execute tests
- Research codebases, find files, or read source code
- Perform multi-step development workflows (create file, write code, run tests)
- Debug errors by reading logs or stack traces
- Generate boilerplate, templates, or scaffolding

## When NOT to use

Do NOT delegate to Pi for:
- Simple factual questions you can answer directly
- Conversational replies that don't involve code or files
- Canvas rendering (use `canvas_render` instead)
- Tasks that only need a verbal explanation

## How to delegate

Pass a clear, specific task description:
```json
{
  "task": "Read src/main.rs and add error handling to the parse_config function"
}
```

Optionally specify a working directory:
```json
{
  "task": "Run cargo test and fix any failures",
  "working_directory": "/home/user/project"
}
```

## Tips

- Be specific about what files to read or modify.
- For multi-step tasks, describe the full workflow in one prompt.
- Pi returns the accumulated response text; summarize the result for the user.
- If Pi reports an error, you may retry with a refined prompt.
