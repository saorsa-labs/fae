//! Procedural tone generation for UI audio cues.
//!
//! Extracted from `pipeline::coordinator::run_playback_stage` to keep DSP
//! concerns separate from pipeline orchestration.

/// Generate a warm two-note thinking tone: A3 (220 Hz) → C4 (262 Hz).
///
/// 300 ms total (150 ms per note) with 40% fade-in/out for a soft ambient feel.
/// Returns mono f32 samples at `sample_rate`.
pub fn generate_thinking_tone(sample_rate: u32) -> Vec<f32> {
    let note_duration = 0.15_f32;
    let n_per_note = (sample_rate as f32 * note_duration) as usize;
    let freq_a3 = 220.0_f32;
    let freq_c4 = 261.63_f32;
    let volume = 0.05_f32;

    let mut tone = Vec::with_capacity(n_per_note * 2);
    for freq in [freq_a3, freq_c4] {
        for i in 0..n_per_note {
            let t = i as f32 / sample_rate as f32;
            let fade_len = (n_per_note as f32 * 0.4) as usize;
            let env = if i < fade_len {
                i as f32 / fade_len as f32
            } else if i > n_per_note - fade_len {
                (n_per_note - i) as f32 / fade_len as f32
            } else {
                1.0
            };
            tone.push(volume * env * (2.0 * std::f32::consts::PI * freq * t).sin());
        }
    }
    tone
}

/// Generate a 200 ms ascending two-note chime (C5 523 Hz → E5 659 Hz).
///
/// Returns mono f32 samples at `sample_rate`.
pub fn generate_listening_tone(sample_rate: u32) -> Vec<f32> {
    let note_duration = 0.10_f32;
    let n_per_note = (sample_rate as f32 * note_duration) as usize;
    let freq_c5 = 523.25_f32;
    let freq_e5 = 659.25_f32;
    let volume = 0.10_f32;

    let mut tone = Vec::with_capacity(n_per_note * 2);
    for freq in [freq_c5, freq_e5] {
        for i in 0..n_per_note {
            let t = i as f32 / sample_rate as f32;
            let fade_len = n_per_note / 5;
            let env = if i < fade_len {
                i as f32 / fade_len as f32
            } else if i > n_per_note - fade_len {
                (n_per_note - i) as f32 / fade_len as f32
            } else {
                1.0
            };
            tone.push(volume * env * (2.0 * std::f32::consts::PI * freq * t).sin());
        }
    }
    tone
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thinking_tone_has_expected_length() {
        let samples = generate_thinking_tone(24_000);
        // 2 notes × 0.15s × 24000 = 7200 samples
        assert_eq!(samples.len(), 7200);
    }

    #[test]
    fn listening_tone_has_expected_length() {
        let samples = generate_listening_tone(24_000);
        // 2 notes × 0.10s × 24000 = 4800 samples
        assert_eq!(samples.len(), 4800);
    }

    #[test]
    fn tones_are_within_amplitude_bounds() {
        for s in generate_thinking_tone(24_000) {
            assert!(s.abs() <= 0.06, "thinking tone sample {s} exceeds bound");
        }
        for s in generate_listening_tone(24_000) {
            assert!(s.abs() <= 0.11, "listening tone sample {s} exceeds bound");
        }
    }
}
