# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///

"""Generate a natural language proposal for the user."""

import json
import sys


def main():
    params = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}

    score = params.get("score")
    previous_score = params.get("previous_score")
    recommendation = params.get("recommendation", "skip")
    adapter_path = params.get("adapter_path", "unknown")
    train_count = params.get("train_count", params.get("sft_train_count", 0))
    valid_count = params.get("valid_count", 0)

    if recommendation == "upgrade":
        if previous_score is not None and score is not None:
            proposal = (
                f"I trained a personal adapter on {train_count} conversations"
                f" ({valid_count} held out for validation). "
                f"Quality score improved from {previous_score:.2f} to {score:.2f}. "
                f"Would you like me to activate it?"
            )
        elif score is not None:
            proposal = (
                f"I trained a personal adapter on {train_count} conversations"
                f" ({valid_count} held out for validation). "
                f"Quality score: {score:.2f}. "
                f"This is the first personal adapter — would you like to try it?"
            )
        else:
            proposal = (
                f"Training completed on {train_count} conversations. "
                f"Would you like me to activate the new adapter?"
            )
    else:
        if score is not None and previous_score is not None:
            proposal = (
                f"Training completed but the new adapter didn't improve over the current one "
                f"(score: {score:.2f} vs {previous_score:.2f}). "
                f"I'll keep using the current configuration."
            )
        else:
            proposal = "Training completed but evaluation was inconclusive. Keeping current configuration."

    print(json.dumps({
        "proposal": proposal,
        "recommendation": recommendation,
        "adapter_path": adapter_path,
    }))


if __name__ == "__main__":
    main()
