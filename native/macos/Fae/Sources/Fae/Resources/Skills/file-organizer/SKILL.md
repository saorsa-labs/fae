---
name: file-organizer
description: Smart file organisation — sort Downloads, clean up Desktop, organise by type/date/project.
metadata:
  author: fae
  version: "1.0"
---

# File Organiser

You are helping the user organise files on their Mac. Use `bash`, `read`, and `write` tools. All operations are local.

## Activation

User says: "clean up my downloads", "organise my desktop", "sort my files", "my downloads folder is a mess".

## Organisation Protocol

### Step 1: Survey the target folder

```bash
# Count files by type
find ~/Downloads -maxdepth 1 -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -15

# List largest files
find ~/Downloads -maxdepth 1 -type f -exec ls -lhS {} + | head -20

# Count total
find ~/Downloads -maxdepth 1 -type f | wc -l
```

### Step 2: Propose a plan

Present the plan BEFORE moving anything:

"Your Downloads folder has 142 files: 45 PDFs, 23 images, 18 DMGs (installers), and various others. Here's what I suggest:
- Move PDFs to ~/Documents/PDFs/
- Move images to ~/Pictures/Downloads/
- Move old DMGs (>30 days) to Trash
- Leave recent files (last 7 days) in place

Want me to proceed?"

### Step 3: Execute with confirmation

Create target directories if needed:
```bash
mkdir -p ~/Documents/PDFs ~/Pictures/Downloads
```

Move files by type:
```bash
# PDFs older than 7 days
find ~/Downloads -maxdepth 1 -name "*.pdf" -mtime +7 -exec mv {} ~/Documents/PDFs/ \;
```

### Step 4: Report results

"Done. Moved 38 PDFs to Documents, 20 images to Pictures, and trashed 15 old installers. Your Downloads folder now has 69 files — mostly recent items from the last week."

## Organisation Strategies

### By Type (default)
Documents → ~/Documents/, Images → ~/Pictures/, Videos → ~/Movies/, Music → ~/Music/

### By Date
Create year/month folders: ~/Documents/2026/03/

### By Project
If the user mentions projects, ask which project each file belongs to and move accordingly.

### Desktop Cleanup
For Desktop specifically, be more conservative:
- Only suggest moving files older than 14 days
- Never move folders without asking
- Offer to create a "Desktop Archive" folder for old items

## Constraints

- ALWAYS show the plan and get approval before moving files.
- NEVER delete files — move to Trash instead (user can recover).
- NEVER touch system files, dotfiles, or ~/Library.
- Preserve file modification dates (use `mv`, not `cp` + `rm`).
- If unsure about a file's purpose, ask the user.
- For large operations (>50 files), process in batches and report progress.
