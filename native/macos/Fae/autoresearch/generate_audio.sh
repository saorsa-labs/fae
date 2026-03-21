#!/bin/bash
# Generate 16kHz mono WAV test audio corpus using macOS say + ffmpeg.
#
# Usage: bash autoresearch/generate_audio.sh
#
# Voices:
#   Primary (owner): Daniel (en_GB male)
#   Stranger 1:      Karen (en_AU female)
#   Stranger 2:      Fred (en_US male)
#   Context:         Moira (en_IE female) — for multi-speaker conversation

set -euo pipefail
cd "$(dirname "$0")/.."  # native/macos/Fae/

AUDIO_DIR="autoresearch/audio"
TMPDIR_AUDIO=$(mktemp -d)
trap "rm -rf $TMPDIR_AUDIO" EXIT

gen() {
    local voice="$1"
    local text="$2"
    local outfile="$3"

    local aiff="$TMPDIR_AUDIO/$(basename "$outfile" .wav).aiff"
    say -v "$voice" -o "$aiff" "$text"
    ffmpeg -y -i "$aiff" -ar 16000 -ac 1 -sample_fmt s16 "$outfile" -loglevel error
}

echo "=== Generating primary user audio (Daniel) ==="

# Enrollment clips (3 distinct utterances for voice enrollment)
gen Daniel "My name is David, and I'm the primary user of this device." \
    "$AUDIO_DIR/enrollment/enroll_1.wav"
gen Daniel "I'd like to set up my voice so you can recognise me." \
    "$AUDIO_DIR/enrollment/enroll_2.wav"
gen Daniel "This is my voice, please remember it for future conversations." \
    "$AUDIO_DIR/enrollment/enroll_3.wav"

# Greetings
gen Daniel "Hello Fae" "$AUDIO_DIR/primary/greeting_hello.wav"
gen Daniel "Good morning" "$AUDIO_DIR/primary/greeting_morning.wav"
gen Daniel "Hey there, how are you?" "$AUDIO_DIR/primary/greeting_howdy.wav"

# Questions
gen Daniel "What time is it?" "$AUDIO_DIR/primary/question_time.wav"
gen Daniel "What day is it today?" "$AUDIO_DIR/primary/question_day.wav"
gen Daniel "What is the capital of France?" "$AUDIO_DIR/primary/question_capital.wav"
gen Daniel "What is 42 times 13?" "$AUDIO_DIR/primary/question_math.wav"
gen Daniel "Tell me three interesting facts about the moon" "$AUDIO_DIR/primary/question_moon.wav"

# Memory
gen Daniel "My name is David" "$AUDIO_DIR/primary/memory_name.wav"
gen Daniel "Remember that my favourite colour is blue" "$AUDIO_DIR/primary/memory_color.wav"
gen Daniel "What's my favourite colour?" "$AUDIO_DIR/primary/memory_recall_color.wav"
gen Daniel "I have a dog named Max" "$AUDIO_DIR/primary/memory_pet.wav"
gen Daniel "What's my dog's name?" "$AUDIO_DIR/primary/memory_recall_pet.wav"
gen Daniel "I work as a software engineer at Saorsa Labs" "$AUDIO_DIR/primary/memory_job.wav"
gen Daniel "Where do I work?" "$AUDIO_DIR/primary/memory_recall_job.wav"

# Personality
gen Daniel "I'm feeling a bit down today" "$AUDIO_DIR/primary/personality_sad.wav"
gen Daniel "Tell me a joke" "$AUDIO_DIR/primary/personality_joke.wav"
gen Daniel "Who are you?" "$AUDIO_DIR/primary/personality_identity.wav"
gen Daniel "What can you help me with?" "$AUDIO_DIR/primary/personality_capabilities.wav"
gen Daniel "Goodbye, talk to you later" "$AUDIO_DIR/primary/personality_farewell.wav"

# Thinking mode
gen Daniel "What is 7 times 8?" "$AUDIO_DIR/primary/think_simple_math.wav"
gen Daniel "Explain quantum entanglement in simple terms" "$AUDIO_DIR/primary/think_complex.wav"
gen Daniel "Is water wet?" "$AUDIO_DIR/primary/think_simple_yesno.wav"

# Capability awareness
gen Daniel "What tools do you have?" "$AUDIO_DIR/primary/capability_tools.wav"
gen Daniel "Can you check my calendar?" "$AUDIO_DIR/primary/capability_calendar.wav"
gen Daniel "Can you order me food?" "$AUDIO_DIR/primary/capability_limitation.wav"
gen Daniel "What skills do you have?" "$AUDIO_DIR/primary/capability_skills.wav"

# Barge-in / interrupt
gen Daniel "Stop" "$AUDIO_DIR/interrupt/stop.wav"
gen Daniel "Wait" "$AUDIO_DIR/interrupt/wait.wav"
gen Daniel "Actually never mind" "$AUDIO_DIR/interrupt/nevermind.wav"
gen Daniel "Hey Fae, different question" "$AUDIO_DIR/interrupt/redirect.wav"
gen Daniel "What time is it?" "$AUDIO_DIR/interrupt/new_question.wav"

# Long prompt (for barge-in testing — Fae will be mid-response)
gen Daniel "Tell me a very long and detailed story about a dragon who lives in a mountain cave and guards a treasure of ancient gold" \
    "$AUDIO_DIR/primary/long_story_prompt.wav"

echo ""
echo "=== Generating stranger audio (Karen + Fred) ==="

# Stranger voices — Fae should NOT respond to these (unless owner is in conversation)
gen Karen "Hello Fae" "$AUDIO_DIR/stranger/karen_greeting.wav"
gen Karen "What time is it?" "$AUDIO_DIR/stranger/karen_question.wav"
gen Karen "Can you help me with something?" "$AUDIO_DIR/stranger/karen_help.wav"
gen Fred "Hey Fae, what's up?" "$AUDIO_DIR/stranger/fred_greeting.wav"
gen Fred "Tell me a joke" "$AUDIO_DIR/stranger/fred_joke.wav"

# Multi-speaker context — owner + stranger in conversation
gen Moira "I was thinking we should go to Edinburgh this weekend" \
    "$AUDIO_DIR/stranger/moira_context.wav"

echo ""
echo "=== Generating noise audio ==="

# Generate silence (1 second)
ffmpeg -y -f lavfi -i "anullsrc=r=16000:cl=mono" -t 3 -sample_fmt s16 \
    "$AUDIO_DIR/noise/silence_3s.wav" -loglevel error

# Generate white noise
ffmpeg -y -f lavfi -i "anoisesrc=d=3:c=white:r=16000:a=0.3" -ac 1 -sample_fmt s16 \
    "$AUDIO_DIR/noise/white_noise_3s.wav" -loglevel error

# Generate pink noise (more natural)
ffmpeg -y -f lavfi -i "anoisesrc=d=3:c=pink:r=16000:a=0.3" -ac 1 -sample_fmt s16 \
    "$AUDIO_DIR/noise/pink_noise_3s.wav" -loglevel error

# Generate tone (simulates music/TV)
ffmpeg -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=16000" -ac 1 -sample_fmt s16 \
    "$AUDIO_DIR/noise/tone_440hz_3s.wav" -loglevel error

echo ""
echo "=== Generating mixed audio (speech over noise) ==="

# Mix primary voice with background noise
if [ -f "$AUDIO_DIR/primary/question_capital.wav" ] && [ -f "$AUDIO_DIR/noise/pink_noise_3s.wav" ]; then
    ffmpeg -y \
        -i "$AUDIO_DIR/primary/question_capital.wav" \
        -i "$AUDIO_DIR/noise/pink_noise_3s.wav" \
        -filter_complex "[1]volume=0.3[noise];[0][noise]amix=inputs=2:duration=shortest" \
        -ar 16000 -ac 1 -sample_fmt s16 -t 5 \
        "$AUDIO_DIR/mixed/speech_over_noise.wav" -loglevel error
fi

echo ""
echo "=== Audio corpus generated ==="
find "$AUDIO_DIR" -name "*.wav" | wc -l | tr -d ' '
echo " WAV files total"
echo ""
du -sh "$AUDIO_DIR"
