"""Generate synthetic test images for VLM evaluation.

Creates simple programmatic "screenshots" that test visual understanding
without requiring actual screen captures. Each image has known content
so we can deterministically check the VLM's response.
"""

from PIL import Image, ImageDraw, ImageFont
from pathlib import Path
import sys

OUT = Path(__file__).parent / "test_images"
OUT.mkdir(exist_ok=True)

W, H = 800, 600
BG = (30, 30, 40)
TEXT_COLOR = (220, 220, 220)
RED = (255, 80, 80)
GREEN = (80, 220, 120)
BLUE = (100, 150, 255)
YELLOW = (255, 200, 60)
GRAY = (120, 120, 130)

try:
    font = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 16)
    font_large = ImageFont.truetype("/System/Library/Fonts/Menlo.ttc", 22)
    font_title = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 18)
except OSError:
    font = ImageFont.load_default()
    font_large = font
    font_title = font


def make_terminal_error():
    """Terminal with a build error."""
    img = Image.new("RGB", (W, H), (20, 20, 30))
    d = ImageDraw.Draw(img)
    # Title bar
    d.rectangle([0, 0, W, 30], fill=(50, 50, 60))
    d.text((15, 6), "Terminal — ~/projects/fae", fill=GRAY, font=font)
    # Terminal content
    lines = [
        ("$ cargo build", TEXT_COLOR),
        ("   Compiling fae v0.8.155", BLUE),
        ("error[E0433]: failed to resolve: use of undeclared type `FooBar`", RED),
        ("  --> src/pipeline.rs:42:15", YELLOW),
        ("   |", GRAY),
        ("42 |     let x: FooBar = Default::default();", TEXT_COLOR),
        ("   |               ^^^^^^ not found in this scope", RED),
        ("", TEXT_COLOR),
        ("error: could not compile `fae` due to 1 previous error", RED),
    ]
    y = 45
    for text, color in lines:
        d.text((15, y), text, fill=color, font=font)
        y += 22
    img.save(OUT / "terminal_error.png")


def make_calendar():
    """Calendar day view with events."""
    img = Image.new("RGB", (W, H), (245, 245, 250))
    d = ImageDraw.Draw(img)
    # Title
    d.rectangle([0, 0, W, 50], fill=(60, 60, 80))
    d.text((20, 14), "Calendar — Wednesday, March 26", fill=(255, 255, 255), font=font_large)
    # Events
    events = [
        (80, "09:00", "Design Review", (70, 130, 220)),
        (160, "11:00", "Team Standup", (80, 180, 120)),
        (280, "13:00", "Lunch with Sam", (220, 140, 60)),
        (400, "16:30", "Dentist Appointment", (200, 80, 80)),
    ]
    for y_pos, time, title, color in events:
        d.rectangle([100, y_pos, 700, y_pos + 60], fill=color, outline=None)
        d.text((115, y_pos + 8), time, fill=(255, 255, 255), font=font_large)
        d.text((115, y_pos + 34), title, fill=(255, 255, 255), font=font)
    img.save(OUT / "calendar_day.png")


def make_code_editor():
    """Xcode-like code editor with Swift code."""
    img = Image.new("RGB", (W, H), (30, 30, 40))
    d = ImageDraw.Draw(img)
    # Title bar
    d.rectangle([0, 0, W, 30], fill=(50, 50, 60))
    d.text((15, 6), "Xcode — PipelineCoordinator.swift", fill=GRAY, font=font)
    # Line numbers + code
    lines = [
        ("  1", "import Foundation", BLUE),
        ("  2", "import FaeInference", BLUE),
        ("  3", "", TEXT_COLOR),
        ("  4", "/// Unified voice pipeline coordinator.", GREEN),
        ("  5", "actor PipelineCoordinator {", TEXT_COLOR),
        ("  6", "    private let engine: MLXLLMEngine", TEXT_COLOR),
        ("  7", "    private let stt: MLXSTTEngine", TEXT_COLOR),
        ("  8", "    private let tts: KokoroMLXTTSEngine", TEXT_COLOR),
        ("  9", "", TEXT_COLOR),
        (" 10", "    func processAudio(_ samples: [Float]) async {", TEXT_COLOR),
        (" 11", "        let transcript = try await stt.transcribe(samples)", TEXT_COLOR),
        (" 12", "        let response = try await engine.generate(", TEXT_COLOR),
    ]
    y = 45
    for num, code, color in lines:
        d.text((10, y), num, fill=GRAY, font=font)
        d.text((55, y), code, fill=color, font=font)
        y += 22
    img.save(OUT / "code_editor.png")


def make_email():
    """Email compose window."""
    img = Image.new("RGB", (W, H), (250, 250, 252))
    d = ImageDraw.Draw(img)
    # Title bar
    d.rectangle([0, 0, W, 40], fill=(60, 60, 80))
    d.text((20, 10), "Mail — New Message", fill=(255, 255, 255), font=font_title)
    # Fields
    fields = [
        (55, "To:", "alex@example.com"),
        (85, "Subject:", "Meeting Thursday at 3 PM"),
    ]
    for y_pos, label, value in fields:
        d.line([15, y_pos + 22, W - 15, y_pos + 22], fill=(200, 200, 210))
        d.text((20, y_pos), label, fill=GRAY, font=font)
        d.text((120, y_pos), value, fill=(40, 40, 50), font=font)
    # Body
    body = [
        "Hi Alex,",
        "",
        "Would Thursday at 3 PM work for a quick sync?",
        "I'd like to review the sprint progress.",
        "",
        "Best,",
        "David",
    ]
    y = 130
    for line in body:
        d.text((25, y), line, fill=(40, 40, 50), font=font)
        y += 22
    img.save(OUT / "email_compose.png")


def make_todo_notes():
    """Notes app with a to-do list."""
    img = Image.new("RGB", (W, H), (255, 252, 235))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 40], fill=(240, 200, 80))
    d.text((20, 10), "Notes — To-Do List", fill=(60, 40, 10), font=font_title)
    items = [
        ("[ ]", "Renew passport before June"),
        ("[x]", "Book dentist appointment"),
        ("[ ]", "Ship beta release v0.9"),
        ("[ ]", "Buy groceries (milk, bread, eggs)"),
        ("[x]", "Send invoice to client"),
        ("[ ]", "Call Mum on Saturday"),
    ]
    y = 60
    for check, text in items:
        color = GRAY if check == "[x]" else (40, 40, 50)
        d.text((30, y), check, fill=GREEN if check == "[x]" else GRAY, font=font)
        d.text((80, y), text, fill=color, font=font)
        y += 35
    img.save(OUT / "todo_notes.png")


def make_weather():
    """Simple weather display."""
    img = Image.new("RGB", (W, H), (40, 60, 100))
    d = ImageDraw.Draw(img)
    d.text((30, 30), "Glasgow", fill=(255, 255, 255), font=font_large)
    d.text((30, 65), "14°C  Partly Cloudy", fill=(200, 220, 255), font=font_large)
    d.text((30, 110), "Wind: 12 mph NW", fill=(180, 200, 230), font=font)
    d.text((30, 140), "Humidity: 72%", fill=(180, 200, 230), font=font)
    d.text((30, 170), "Sunrise: 06:45  Sunset: 19:22", fill=(180, 200, 230), font=font)

    # Forecast
    d.text((30, 230), "3-Day Forecast", fill=(255, 255, 255), font=font_title)
    forecasts = [
        ("Thu", "16°C", "Sunny"),
        ("Fri", "12°C", "Rain"),
        ("Sat", "13°C", "Cloudy"),
    ]
    x = 50
    for day, temp, desc in forecasts:
        d.text((x, 270), day, fill=(200, 220, 255), font=font)
        d.text((x, 295), temp, fill=(255, 255, 255), font=font_large)
        d.text((x, 325), desc, fill=(180, 200, 230), font=font)
        x += 220
    img.save(OUT / "weather.png")


if __name__ == "__main__":
    make_terminal_error()
    make_calendar()
    make_code_editor()
    make_email()
    make_todo_notes()
    make_weather()
    count = len(list(OUT.glob("*.png")))
    print(f"Generated {count} test images in {OUT}/")
