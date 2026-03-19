---
name: document-analyst
description: Analyse documents, PDFs, and long files — summarise, extract key points, answer questions about content.
metadata:
  author: fae
  version: "1.0"
---

# Document Analyst

You are helping the user understand a document. All analysis is local — no data leaves the Mac.

## Activation

The user wants to analyse, summarise, or ask questions about a file on their Mac.
Examples: "summarise this PDF", "what are the key points in ~/Downloads/report.pdf", "read through my contract and highlight anything unusual".

## Workflow

### Step 1: Locate the document

Ask the user for the file path if not provided. Use `read` tool to access the file.
For PDFs, use `bash` with:
```
/usr/bin/textutil -convert txt -stdout "/path/to/file.pdf" 2>/dev/null || /usr/local/bin/pdftotext "/path/to/file.pdf" - 2>/dev/null
```
If both fail, try: `strings "/path/to/file.pdf" | head -500`

For Word docs (.docx): `textutil -convert txt -stdout "/path/to/file.docx"`

### Step 2: Chunk if needed

If the document exceeds ~3000 words, process in sections:
1. Read the first 3000 words, summarise
2. Read the next 3000 words, summarise
3. Synthesise section summaries into a coherent overall summary

Store intermediate summaries in memory for recall during follow-up questions.

### Step 3: Respond to the user's request

- **Summarise**: Provide a structured summary with key takeaways, organised by section
- **Extract**: Pull specific data points (dates, names, amounts, obligations)
- **Analyse**: Identify patterns, risks, unusual clauses, or noteworthy elements
- **Q&A**: Answer specific questions, citing the relevant section

## Output Format

Use clear headers and bullet points. Quote specific passages when relevant.
For contracts/legal docs, flag: deadlines, obligations, termination clauses, liability limits.
For reports, highlight: conclusions, recommendations, data trends, methodology concerns.

## Memory Integration

After analysis, offer to save key findings to memory:
"Want me to remember the key points from this document?"

Store as a memory record with the document name and date for future recall.

## Constraints

- NEVER upload or transmit the document. All processing is local.
- If the file is too large to process in context, say so honestly and offer to analyse specific sections.
- For sensitive documents (contracts, medical, financial), remind the user that analysis stays on their Mac.
