//! Developer tool: slice a single avatar sheet PNG into individual assets.
//!
//! This is feature-gated behind `tools` so it doesn't affect normal builds.

#![cfg(feature = "tools")]

use std::path::{Path, PathBuf};

fn main() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    let sheet = args
        .next()
        .ok_or_else(|| "usage: fae-avatar-slicer <sheet.png> [out_dir]".to_owned())?;
    let out_dir = args
        .next()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("assets/avatar"));

    slice_sheet(Path::new(&sheet), &out_dir)?;
    eprintln!("Wrote avatar assets to {}", out_dir.display());
    Ok(())
}

fn slice_sheet(sheet_path: &Path, out_dir: &Path) -> Result<(), String> {
    use image::{ImageBuffer, Rgba};

    std::fs::create_dir_all(out_dir).map_err(|e| e.to_string())?;

    let img = image::open(sheet_path)
        .map_err(|e| format!("failed to open {}: {e}", sheet_path.display()))?
        .to_rgba8();
    let (w, h) = img.dimensions();

    // Expected names in reading order (left-to-right, top-to-bottom), 6 columns x 3 rows.
    let expected = [
        // Row 1
        "fae_base.png",
        "mouth_open_small.png",
        "mouth_open_medium.png",
        "mouth_open_wide.png",
        "eyes_blink.png",
        "eyes_look_left.png",
        // Row 2
        "eyes_look_left_2.png",
        "mouth_smile_talk.png",
        "mouth_fv.png",
        "mouth_th.png",
        "mouth_mbp.png",
        "fae_centered.png",
        // Row 3
        "eyes_look_right.png",
        "eyes_open.png",
        "eyes_open_2.png",
        "mouth_surprised.png",
        "mouth_sad.png",
        "mouth_angry.png",
    ];

    let cols: u32 = 6;
    let rows: u32 = 3;
    let cell_w = w / cols;
    let cell_h = h / rows;

    eprintln!(
        "Sheet {}x{}, grid {cols}x{rows}, cell ~{cell_w}x{cell_h}",
        w, h
    );

    for (i, name) in expected.iter().enumerate() {
        let col = (i as u32) % cols;
        let row = (i as u32) / cols;

        let x0 = col * cell_w;
        let y0 = row * cell_h;
        // Last column/row absorbs any remainder pixels.
        let cw = if col == cols - 1 { w - x0 } else { cell_w };
        let ch = if row == rows - 1 { h - y0 } else { cell_h };

        let mut out: ImageBuffer<Rgba<u8>, Vec<u8>> = ImageBuffer::new(cw, ch);
        for oy in 0..ch {
            for ox in 0..cw {
                let px = img.get_pixel(x0 + ox, y0 + oy);
                out.put_pixel(ox, oy, *px);
            }
        }

        let out_path = out_dir.join(name);
        out.save(&out_path)
            .map_err(|e| format!("failed to save {}: {e}", out_path.display()))?;
        eprintln!("  [{i:>2}] {name} ({cw}x{ch} @ {x0},{y0})");
    }

    Ok(())
}
