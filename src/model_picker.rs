//! Model picker helpers (GGUF file selection + UX heuristics).

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OptimizeFor {
    Speed,
    #[default]
    Balanced,
    Quality,
}

impl std::str::FromStr for OptimizeFor {
    type Err = ();

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Ok(Self::parse(s))
    }
}

impl OptimizeFor {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Speed => "speed",
            Self::Balanced => "balanced",
            Self::Quality => "quality",
        }
    }

    pub fn parse(s: &str) -> Self {
        match s {
            "speed" => Self::Speed,
            "quality" => Self::Quality,
            _ => Self::Balanced,
        }
    }
}

pub fn curated_recommended_model_ids() -> &'static [&'static str] {
    // Keep this list small and "assistant-friendly" (instruct/chat).
    &[
        "unsloth/Qwen3-4B-Instruct-2507-GGUF",
        "MaziyarPanahi/Qwen3-4B-Instruct-GGUF",
        "hugging-quants/Llama-3.2-3B-Instruct-Q8_0-GGUF",
        "hugging-quants/Llama-3.2-1B-Instruct-Q8_0-GGUF",
        "unsloth/GLM-4.7-Flash-GGUF",
    ]
}

pub fn extract_gguf_files(siblings: &[String]) -> Vec<String> {
    let mut out = siblings
        .iter()
        .filter(|f| f.to_ascii_lowercase().ends_with(".gguf"))
        .cloned()
        .collect::<Vec<_>>();
    out.sort_by_key(|f| score_quant(f));
    out
}

pub fn has_tokenizer_json(siblings: &[String]) -> bool {
    siblings.iter().any(|f| f == "tokenizer.json")
}

fn score_quant(filename: &str) -> i32 {
    // Lower is better. This is just used for "nearest match" ordering.
    let f = filename.to_ascii_uppercase();
    if f.contains("F16") {
        10
    } else if f.contains("BF16") || f.contains("F32") {
        20
    } else if f.contains("Q8_0") || f.contains("Q8") {
        30
    } else if f.contains("Q6_K") || f.contains("Q6") {
        40
    } else if f.contains("Q5_K_M") || f.contains("Q5_K_S") || f.contains("Q5") {
        50
    } else if f.contains("Q4_K_M")
        || f.contains("Q4_K_S")
        || f.contains("Q4_1")
        || f.contains("Q4_0")
    {
        60
    } else if f.contains("Q3_K_M") || f.contains("Q3_K_S") || f.contains("Q3") {
        70
    } else if f.contains("Q2_K") || f.contains("Q2") {
        80
    } else {
        90
    }
}

pub fn auto_pick_gguf_file(
    gguf_files: &[String],
    optimize_for: OptimizeFor,
    file_sizes: &[(String, Option<u64>)],
    ram_bytes: Option<u64>,
) -> Option<String> {
    if gguf_files.is_empty() {
        return None;
    }

    // Target "max weight size" is ~40% of RAM. This is crude but prevents obvious OOM choices.
    let max_bytes = ram_bytes.map(|r| (r as f64 * 0.40) as u64);

    let mut candidates = gguf_files
        .iter()
        .map(|f| {
            let size = file_sizes
                .iter()
                .find(|(name, _)| name == f)
                .and_then(|(_, sz)| *sz);
            (f.clone(), size)
        })
        .collect::<Vec<_>>();

    // Prefer known quant tags, stable ordering.
    candidates.sort_by_key(|(f, _)| score_quant(f));

    let preferred_order: &[&str] = match optimize_for {
        OptimizeFor::Speed => &["Q4_K_M", "Q4_0", "Q3_K_M", "Q3_K_S", "Q2_K"],
        OptimizeFor::Balanced => &["Q4_K_M", "Q5_K_M", "Q5_K_S", "Q4_0", "Q6_K"],
        OptimizeFor::Quality => &["Q6_K", "Q8_0", "F16", "BF16", "Q5_K_M"],
    };

    // Helper to choose "best match" among candidates by preferred tags.
    let mut pick_by_pref = Vec::new();
    for tag in preferred_order {
        for (f, sz) in &candidates {
            if f.to_ascii_uppercase().contains(tag) {
                pick_by_pref.push((f.clone(), *sz));
            }
        }
    }
    // Fallback: whatever is there.
    if pick_by_pref.is_empty() {
        pick_by_pref = candidates.clone();
    }

    // Filter by RAM if we have sizes + RAM estimate.
    if let Some(max) = max_bytes {
        let mut filtered = pick_by_pref
            .iter()
            .filter(|(_, sz)| sz.is_none_or(|b| b <= max))
            .cloned()
            .collect::<Vec<_>>();
        if !filtered.is_empty() {
            // Prefer "largest that fits" within the filtered set by quant score, then by size.
            filtered.sort_by_key(|(f, sz)| (score_quant(f), sz.unwrap_or(u64::MAX)));
            return filtered.first().map(|(f, _)| f.clone());
        }
    }

    pick_by_pref.first().map(|(f, _)| f.clone())
}
