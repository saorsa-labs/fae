# Fae Avatar Pack v2

Drop the avatar assets in this directory.

For released builds, the app also looks for avatar assets in `~/.fae/avatar/`.

If you currently have a single "sprite sheet" PNG (6x3 grid, 18 poses), you can
auto-slice it into the files below using:

`just slice-avatar assets/avatar/sheet.png`

(or directly: `cargo run --features tools --bin fae-avatar-slicer -- assets/avatar/sheet.png assets/avatar`)

## Expected files (18 poses, 6x3 grid)

Row 1:
- `fae_base.png` — neutral base pose (used as animation base when running)
- `mouth_open_small.png` — slight mouth opening
- `mouth_open_medium.png` — medium mouth opening
- `mouth_open_wide.png` — wide mouth opening
- `eyes_blink.png` — eyes closed / blinking
- `eyes_look_left.png` — eyes looking left

Row 2:
- `eyes_look_left_2.png` — eyes looking left variant
- `mouth_smile_talk.png` — smiling while talking
- `mouth_fv.png` — "F" / "V" mouth shape
- `mouth_th.png` — "TH" mouth shape
- `mouth_mbp.png` — "M" / "B" / "P" mouth shape (closed lips)
- `fae_centered.png` — centered neutral pose variant

Row 3:
- `eyes_look_right.png` — eyes looking right
- `eyes_open.png` — eyes open (used for patch overlay mode)
- `eyes_open_2.png` — eyes open variant
- `mouth_surprised.png` — surprised expression
- `mouth_sad.png` — sad expression
- `mouth_angry.png` — angry expression

## Idle vs Running states

- **Idle/Stopped**: The app shows the full uncropped woodland image (`assets/fae.jpg`)
  as a rectangular portrait.
- **Running**: The app shows a circular animated avatar using `fae_base.png` with
  mouth/eye overlays swapped based on speech RMS levels and blink timing.

## Layout anchors

See `fae_avatar_layout.json` for mouth/eye anchor positions within the base portrait.

## Overlay modes

The GUI supports two overlay modes:
- **Patch overlays** (cropped mouth/eyes): if `eyes_open.png` exists, overlays are
  positioned using `fae_avatar_layout.json` anchors.
- **Full-canvas overlays**: overlays are the same dimensions as `fae_base.png` and the
  GUI uses `clip-path` to show only the mouth/eyes region.

## Slicer

The slicer divides the sheet into a 6-column x 3-row uniform grid. It does not require
transparency-separated sprites.
