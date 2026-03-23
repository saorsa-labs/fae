# Security Review
**Date**: 2026-03-21

## Findings
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:148:    if hasattr(result, "tokens"):
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:149:        text = "".join(t.text for t in result.tokens)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:153:    if hasattr(result, "tokens"):
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:154:        text = "".join(t.text for t in result.tokens)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/timing_evaluator.py:40:                    metrics["llm_tokens_per_second"] = float(tps_str)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/timing_evaluator.py:43:        if "tokens in" in text:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/timing_evaluator.py:45:                parts = text.split("tokens in")
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/timing_evaluator.py:46:                token_part = parts[0].split()[-1]
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/timing_evaluator.py:48:                metrics["llm_token_count"] = int(token_part)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/timing_evaluator.py:98:    tps_values = [r.get("llm_tokens_per_second", 0) for r in dim_results if r.get("llm_tokens_per_second")]
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/runners/inject_runner.py:24:BASE_URL = "http://127.0.0.1:7433"
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/runners/voice_pipeline_runner.py:24:BASE_URL = "http://127.0.0.1:7433"
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:9:        uv run autoresearch/asr_accuracy_eval.py
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:12:    ... uv run autoresearch/asr_accuracy_eval.py --corpus path/to/clips
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:15:    ... uv run autoresearch/asr_accuracy_eval.py --models parakeet
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:125:    mx.eval(mx.array([0]))  # sync
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:209:# Main evaluation
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:212:def run_eval(corpus_dir: Path, model_names: list[str], output_dir: Path) -> ComparisonResult:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:213:    """Run ASR evaluation across models on the corpus."""
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:441:        help="Which models to evaluate (default: both)",
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_accuracy_eval.py:467:    comparison = run_eval(args.corpus, args.models, args.output)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_record_clips.py:5:"""Record audio clips for ASR accuracy evaluation.
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:16:        uv run autoresearch/asr_streaming_eval.py
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:19:    ... uv run autoresearch/asr_streaming_eval.py --models parakeet
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:22:    ... uv run autoresearch/asr_streaming_eval.py --chunk-ms 250
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:136:    mx.eval(mx.array([0]))
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:289:# Main evaluation
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:304:def run_streaming_eval(
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/asr_streaming_eval.py:488:    comparison = run_streaming_eval(args.corpus, args.models, args.chunk_ms, args.output)
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/timing_evaluator.py:117:    parser = argparse.ArgumentParser(description="FaeAutoResearch timing evaluator")
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/accuracy_evaluator.py:13:def evaluate_result(result: dict) -> dict:
/Users/davidirvine/Desktop/Devel/projects/fae/native/macos/Fae/autoresearch/evaluators/accuracy_evaluator.py:122:    parser = argparse.ArgumentParser(description="FaeAutoResearch accuracy evaluator")

## Assessment
Task diff is JSON state updates (metrics/scores) and a deleted profraw file.
No credentials, secrets, or unsafe patterns introduced.
New Python scripts are research/evaluation tools — subprocess use is appropriate for audio tools.

## Grade: A
