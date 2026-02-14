//! Viseme mapping for lip-sync animation.
//!
//! A viseme is a visual mouth shape that corresponds to a phoneme (sound).
//! This module maps phonemes to visemes for 2D avatar animation.

use crate::tts::kokoro::phonemize::Phonemizer;

/// Oculus viseme IDs (standard for lip-sync)
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum Viseme {
    /// Silence (default mouth closed)
    Sil = 0,
    /// /p/, /b/, /m/ (lips pressed together)
    PP = 1,
    /// /f/, /v/ (teeth on lip)
    FF = 2,
    /// /θ/, /ð/ (tongue between teeth)
    TH = 3,
    /// /t/, /d/, /n/, /l/ (tongue at roof)
    DD = 4,
    /// /k/, /g/, /ŋ/ (back of tongue up)
    KK = 5,
    /// /tʃ/, /dʒ/, /ʃ/, /ʒ/ (tongue curved)
    CH = 6,
    /// /s/, /z/ (teeth together, tongue forward)
    SS = 7,
    /// /n/, /nj/ (tongue at roof)
    NN = 8,
    /// /r/ (tongue curled)
    RR = 9,
    /// /a/ (mouth open wide)
    AA = 10,
    /// /e/ (mouth medium)
    E = 11,
    /// /i/ (mouth wide, teeth apart)
    I = 12,
    /// /o/ (rounded, medium)
    O = 13,
    /// /u/ (rounded, small)
    U = 14,
}

impl Viseme {
    /// Get the filename for this viseme based on available PNG assets.
    pub fn to_png_name(&self) -> &'static str {
        match self {
            Viseme::Sil => "mouth_closed.png",     // Use base pose
            Viseme::PP => "mouth_mbp.png",         // Closed lips (M/B/P)
            Viseme::FF => "mouth_fv.png",          // Teeth on lip (F/V)
            Viseme::TH => "mouth_th.png",          // Tongue between teeth
            Viseme::DD => "mouth_open_small.png",  // Slight open
            Viseme::KK => "mouth_open_medium.png", // Medium open
            Viseme::CH => "mouth_open_medium.png",
            Viseme::SS => "mouth_open_small.png", // Teeth apart
            Viseme::NN => "mouth_open_small.png",
            Viseme::RR => "mouth_open_medium.png",
            Viseme::AA => "mouth_open_wide.png", // Wide open
            Viseme::E => "mouth_open_medium.png",
            Viseme::I => "mouth_smile_talk.png", // Wide smile
            Viseme::O => "mouth_open_medium.png",
            Viseme::U => "mouth_fv.png", // Rounded small
        }
    }

    /// Get the PNG name for Scottish English (fae accent)
    pub fn to_png_name_scottish(&self) -> &'static str {
        // Fae has a Scottish accent - slight variations
        self.to_png_name()
    }
}

/// ARPABET phoneme to viseme mapping.
/// Based on Carnegie Mellon University Pronouncing Dictionary.
fn phoneme_to_viseme(phoneme: &str) -> Viseme {
    // Remove stress markers (0, 1, 2)
    let p = phoneme.trim_end_matches(['0', '1', '2']);

    match p {
        // Silence
        "" | "sil" | "sp" => Viseme::Sil,

        // Bilabial: lips together
        "B" | "P" | "M" | "EM" | "MX" => Viseme::PP,

        // Labiodental: teeth on lip
        "F" | "V" => Viseme::FF,

        // Dental: tongue between teeth
        "TH" | "DH" => Viseme::TH,

        // Alveolar: tongue at roof
        "T" | "D" | "N" | "L" | "DX" | "NX" | "EL" | "EN" => Viseme::DD,

        // Velar: back of tongue
        "K" | "G" | "NG" => Viseme::KK,

        // Postalveolar: curled
        "CH" | "JH" | "SH" | "ZH" | "RR" => Viseme::CH,

        // Alveolar sibilants
        "S" | "Z" => Viseme::SS,

        // Vowels - single match each to avoid overlaps
        "AA" | "AO" | "AW" => Viseme::AA,
        "AE" | "AH" | "EH" | "ER" => Viseme::E,
        "AY" | "EY" | "IH" | "IY" | "Y" => Viseme::I,
        "OW" | "OY" => Viseme::O,
        "UH" => Viseme::O,
        "UW" => Viseme::U,

        // Default to slight open for unknown
        _ => Viseme::DD,
    }
}

/// Convert a sequence of phonemes to visemes with estimated durations.
///
/// Phonemes are in ARPABET format (from misaki G2P).
/// Returns vec of (viseme, start_time_ms, duration_ms).
pub fn phonemes_to_visemes(phonemes: &str, speech_rate: f32) -> Vec<(Viseme, f32, f32)> {
    let mut result = Vec::new();

    // Split phonemes (they're space-separated)
    let phones: Vec<&str> = phonemes.split_whitespace().collect();

    if phones.is_empty() {
        return result;
    }

    // Base duration per phoneme in ms (at 1.0 rate)
    let base_duration = 80.0;
    let duration = base_duration / speech_rate.max(0.5);

    for phone in phones {
        // Skip silence markers
        if phone == "sil" || phone == "sp" {
            continue;
        }

        let viseme = phoneme_to_viseme(phone);

        // Estimate duration based on phoneme type
        let phone_duration = match phone {
            // Longer for vowels
            "AA" | "AE" | "AH" | "AO" | "AW" | "AY" | "EH" | "EY" | "IH" | "IY" | "OW" | "OY"
            | "UH" | "UW" | "ER" => duration * 1.5,
            // Shorter for consonants
            "P" | "B" | "T" | "D" | "K" | "G" | "M" | "N" | "F" | "V" | "S" | "Z" => duration * 0.8,
            // Default
            _ => duration,
        };

        // Skip if same as previous viseme (smooths animation)
        if let Some((last_viseme, _, _)) = result.last()
            && *last_viseme == viseme
        {
            // Extend previous duration
            if let Some((_, start, d)) = result.pop() {
                result.push((viseme, start, d + phone_duration));
            }
            continue;
        }

        let start = result.len() as f32 * duration;
        result.push((viseme, start, phone_duration));
    }

    result
}

/// Convert text directly to visemes (convenience function).
///
/// This is the main entry point for text-to-viseme conversion.
pub fn text_to_visemes(text: &str, speech_rate: f32) -> Vec<(Viseme, f32, f32)> {
    // Use the existing phonemizer from tts/kokoro
    let phonemizer = Phonemizer::new(false); // American English
    match phonemizer.phonemize(text) {
        Ok(phonemes) => phonemes_to_visemes(phonemes.as_str(), speech_rate),
        Err(_) => Vec::new(), // Fallback to empty on error
    }
}

/// Get a mouth PNG name for a viseme.
pub fn viseme_to_mouth_png(viseme: Viseme) -> &'static str {
    viseme.to_png_name()
}

/// Estimate total duration of text in milliseconds.
pub fn estimate_duration(text: &str, words_per_minute: f32) -> f32 {
    let word_count = text.split_whitespace().count() as f32;
    let minutes = word_count / words_per_minute.max(30.0);
    minutes * 60.0 * 1000.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_vowels_to_visemes() {
        let visemes = phonemes_to_visemes("AA OW IH", 1.0);
        assert!(!visemes.is_empty());
        // Should have different visemes for different vowels
    }

    #[test]
    fn test_consonants_to_visemes() {
        let visemes = phonemes_to_visemes("B P M", 1.0);
        // All should map to PP (bilabial)
        for (v, _, _) in &visemes {
            assert_eq!(*v, Viseme::PP);
        }
    }

    #[test]
    fn test_text_to_visemes() {
        let result = text_to_visemes("Hello world", 1.0);
        // Should produce some visemes
        assert!(!result.is_empty());
    }

    #[test]
    fn test_estimate_duration() {
        let dur = estimate_duration("Hello world", 150.0);
        // ~2 words at 150 wpm = ~0.8 seconds = 800ms
        assert!(dur > 500.0 && dur < 1500.0);
    }
}
