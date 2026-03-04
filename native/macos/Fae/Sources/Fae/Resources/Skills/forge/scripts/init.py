#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Scaffold a new Forge tool project with templates, git init, and initial commit."""

import json
import os
import re
import subprocess
import sys


FORGE_BASE = os.path.expanduser("~/.fae-forge")
WORKSPACE = os.path.join(FORGE_BASE, "workspace")


def validate_name(name: str) -> str | None:
    """Return an error message if name is invalid, else None."""
    if not name:
        return "Tool name is required."
    if not re.match(r"^[a-z][a-z0-9-]*$", name):
        return (
            "Tool name must be lowercase, start with a letter, and contain "
            "only letters, digits, and hyphens."
        )
    if len(name) > 64:
        return "Tool name must be 64 characters or fewer."
    return None


def write_file(path: str, content: str) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)


# ---------------------------------------------------------------------------
# Templates
# ---------------------------------------------------------------------------

def zig_main_template(name: str, description: str) -> str:
    return f"""\
const std = @import("std");

pub fn main() !void {{
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    // Read JSON from stdin.
    var buf: [4096]u8 = undefined;
    var total: usize = 0;
    while (true) {{
        const n = stdin.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }}
    const input = buf[0..total];

    // TODO: Parse input JSON and implement {name} logic.
    _ = input;

    // Write JSON result to stdout.
    try stdout.print("{{\\"ok\\": true, \\"message\\": \\"{description}\\"}}\\n", .{{}});
}}
"""


def zig_test_template(name: str) -> str:
    return f"""\
const std = @import("std");

test "{name} basic" {{
    // TODO: Add tests for {name}.
    try std.testing.expect(true);
}}
"""


def zig_build_template(name: str) -> str:
    return f"""\
const std = @import("std");

pub fn build(b: *std.Build) void {{
    const target = b.standardTargetOptions(.{{}});
    const optimize = b.standardOptimizeOption(.{{}});

    const exe = b.addExecutable(.{{
        .name = "{name}",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }});
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the tool");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{{
        .root_source_file = b.path("tests/main_test.zig"),
        .target = target,
        .optimize = optimize,
    }});
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}}
"""


def zig_build_zon_template(name: str, description: str) -> str:
    return f"""\
.{{
    .name = "{name}",
    .version = "0.1.0",
    .paths = .{{
        "build.zig",
        "build.zig.zon",
        "src",
        "tests",
    }},
}}
"""


def python_script_template(name: str, description: str) -> str:
    safe_name = name.replace("-", "_")
    return f"""\
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
\"\"\"{description}\"\"\"

import json
import sys


def run(params: dict) -> dict:
    \"\"\"Main entry point for {name}.\"\"\"
    # TODO: Implement {name} logic.
    input_data = params.get("input", "")
    return {{
        "ok": True,
        "message": "Hello from {name}",
        "input_received": input_data,
    }}


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {{}})
    try:
        result = run(params)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({{"ok": False, "error": str(e)}}))


if __name__ == "__main__":
    main()
"""


def skill_md_template(name: str, description: str, lang: str) -> str:
    lang_label = {"zig": "Zig", "python": "Python", "both": "Zig + Python"}.get(lang, lang)
    return f"""\
---
name: {name}
description: {description}
metadata:
  author: user
  version: "0.1.0"
---

{name} -- {description}

Language: {lang_label}

## Usage

Run via `run_skill` with name `{name}`.
"""


# ---------------------------------------------------------------------------
# Scaffolding
# ---------------------------------------------------------------------------

def scaffold_zig(project_dir: str, name: str, description: str) -> list[str]:
    """Create Zig project files. Returns list of created files."""
    files = []

    path = os.path.join(project_dir, "src", "main.zig")
    write_file(path, zig_main_template(name, description))
    files.append("src/main.zig")

    path = os.path.join(project_dir, "tests", "main_test.zig")
    write_file(path, zig_test_template(name))
    files.append("tests/main_test.zig")

    path = os.path.join(project_dir, "build.zig")
    write_file(path, zig_build_template(name))
    files.append("build.zig")

    path = os.path.join(project_dir, "build.zig.zon")
    write_file(path, zig_build_zon_template(name, description))
    files.append("build.zig.zon")

    return files


def scaffold_python(project_dir: str, name: str, description: str) -> list[str]:
    """Create Python project files. Returns list of created files."""
    safe_name = name.replace("-", "_")
    files = []

    path = os.path.join(project_dir, "scripts", f"{safe_name}.py")
    write_file(path, python_script_template(name, description))
    os.chmod(path, 0o755)
    files.append(f"scripts/{safe_name}.py")

    return files


def git_init(project_dir: str, name: str) -> bool:
    """Initialize git repo and make initial commit. Returns True on success."""
    try:
        subprocess.run(
            ["git", "init"],
            cwd=project_dir,
            capture_output=True,
            check=True,
        )
        subprocess.run(
            ["git", "add", "."],
            cwd=project_dir,
            capture_output=True,
            check=True,
        )
        subprocess.run(
            ["git", "commit", "-m", f"Initial scaffold for {name}"],
            cwd=project_dir,
            capture_output=True,
            check=True,
            env={**os.environ, "GIT_AUTHOR_NAME": "Fae Forge", "GIT_COMMITTER_NAME": "Fae Forge",
                 "GIT_AUTHOR_EMAIL": "forge@fae.local", "GIT_COMMITTER_EMAIL": "forge@fae.local"},
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def init_project(name: str, lang: str, description: str) -> dict:
    """Scaffold a new tool project."""
    err = validate_name(name)
    if err:
        return {"ok": False, "error": err}

    if lang not in ("zig", "python", "both"):
        return {"ok": False, "error": f"Unsupported language: {lang!r}. Use 'zig', 'python', or 'both'."}

    project_dir = os.path.join(WORKSPACE, name)
    if os.path.exists(project_dir):
        return {"ok": False, "error": f"Project '{name}' already exists at {project_dir}. Delete it first or choose a different name."}

    os.makedirs(project_dir, exist_ok=True)

    created_files = []

    # Write SKILL.md.
    skill_path = os.path.join(project_dir, "SKILL.md")
    write_file(skill_path, skill_md_template(name, description, lang))
    created_files.append("SKILL.md")

    # Scaffold language-specific files.
    if lang in ("zig", "both"):
        created_files.extend(scaffold_zig(project_dir, name, description))
    if lang in ("python", "both"):
        created_files.extend(scaffold_python(project_dir, name, description))

    # Git init.
    git_ok = git_init(project_dir, name)

    return {
        "ok": True,
        "path": project_dir,
        "lang": lang,
        "files_created": created_files,
        "git_initialized": git_ok,
        "message": f"Project '{name}' scaffolded at {project_dir}. Ready to develop!",
    }


def main():
    request = json.loads(sys.stdin.read())
    params = request.get("params", {})
    name = params.get("name", "")
    lang = params.get("lang", "")
    description = params.get("description", "A custom Fae tool")
    try:
        result = init_project(name, lang, description)
        print(json.dumps(result, indent=2))
    except Exception as e:
        print(json.dumps({"ok": False, "error": str(e)}))


if __name__ == "__main__":
    main()
