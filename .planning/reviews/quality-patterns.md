# Quality Patterns Review
**Date**: 2026-03-21

## Good Patterns Found
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:49:from dataclasses import asdict, dataclass, field
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:61:@dataclass
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:72:@dataclass
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:84:@dataclass
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:38:from dataclasses import asdict, dataclass, field
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:59:@dataclass
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:69:@dataclass
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:83:@dataclass
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:97:@dataclass
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/runners/inject_runner.py:11:from dataclasses import asdict, dataclass, field
- Uses @dataclass for result types (ClipResult, ModelResult, ComparisonResult) — good
- Uses PEP 723 inline script dependencies (# /// script) for uv compatibility
- SSL_CERT_FILE fix for zerobrew Python is a good defensive pattern
- WER computation via jiwer library (established, correct tool)
- Proper use of argparse for CLI

## Anti-Patterns Found
- [LOW] Some broad `except Exception` handlers in evaluation scripts (acceptable for research tools)
- [LOW] Default.profraw was tracked (deleted in this diff — correct fix)
- [MEDIUM] barge_in regression in autoresearch metrics (71→42) indicates a real regression in recent commits — warrants investigation

## Grade: B
