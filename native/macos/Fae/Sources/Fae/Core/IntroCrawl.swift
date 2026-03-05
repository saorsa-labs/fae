import Foundation

/// "Fae — First Contact" glassmorphic startup canvas.
///
/// Shown at first launch before model loading begins. Returns HTML snippets
/// (CSS + body divs) — NOT a full document — so `CanvasHTMLView.loadHTML()`
/// can wrap them with `background: transparent`, allowing the canvas panel's
/// `NSVisualEffectView` glass to show through.
///
/// Replaced by `LoadingCanvasContent.crawlExperience()` once model loading starts.
enum IntroCrawl {

    /// HTML snippets for the First Contact canvas — pass to `CanvasController.setContent(_:)`.
    static var fullHTML: String {
        "\(css)\n\(html)"
    }

    // MARK: - CSS

    private static let css = """
    <style>
      body {
        background: transparent !important;
        padding: 0 !important;
        margin: 0;
        overflow: hidden;
      }

      /* ── Aurora blobs: soft colored radials drifting over the glass ── */

      .aurora {
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        pointer-events: none;
        z-index: 0;
      }

      /* Each blob handles its own fade-in inside its keyframes so */
      /* we don't need JS or animation chaining tricks. */

      .blob {
        position: absolute;
        border-radius: 50%;
        filter: blur(52px);
      }

      .blob-1 {
        width: 240px; height: 240px;
        background: radial-gradient(circle, rgba(180, 168, 196, 0.7), transparent 70%);
        top: -90px; left: -70px;
        animation: blob-1 13s ease-in-out infinite;
      }

      @keyframes blob-1 {
        0%   { opacity: 0;    transform: translate(0, 0) scale(1); }
        12%  { opacity: 0.18; transform: translate(0, 0) scale(1); }
        55%  { opacity: 0.18; transform: translate(24px, 18px) scale(1.09); }
        100% { opacity: 0.18; transform: translate(0, 0) scale(1); }
      }

      .blob-2 {
        width: 200px; height: 200px;
        background: radial-gradient(circle, rgba(91, 163, 217, 0.55), transparent 70%);
        bottom: -65px; right: -55px;
        animation: blob-2 15s ease-in-out 0.6s infinite;
      }

      @keyframes blob-2 {
        0%   { opacity: 0;    transform: translate(0, 0) scale(1); }
        10%  { opacity: 0.14; transform: translate(0, 0) scale(1); }
        60%  { opacity: 0.14; transform: translate(-22px, -16px) scale(1.07); }
        100% { opacity: 0.14; transform: translate(0, 0) scale(1); }
      }

      .blob-3 {
        width: 160px; height: 160px;
        background: radial-gradient(circle, rgba(140, 110, 195, 0.5), transparent 70%);
        top: calc(38% - 80px);
        left: calc(50% - 80px);
        animation: blob-3 10s ease-in-out 1.1s infinite;
      }

      @keyframes blob-3 {
        0%   { opacity: 0;    transform: translate(0, 0) scale(1); }
        14%  { opacity: 0.11; transform: translate(0, 0) scale(1); }
        50%  { opacity: 0.11; transform: translate(14px, -12px) scale(1.05); }
        100% { opacity: 0.11; transform: translate(0, 0) scale(1); }
      }

      /* ── Main layout ── */

      .first-contact {
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        z-index: 10;
        padding: 24px;
        gap: 0;
      }

      /* ── "FIRST CONTACT" eyebrow label ── */

      .fc-label {
        font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif;
        font-size: 9px;
        font-weight: 600;
        letter-spacing: 4px;
        text-transform: uppercase;
        color: #B4A8C4;
        margin-bottom: 20px;
        opacity: 0;
        animation: fc-label-in 1.5s cubic-bezier(0.16, 1, 0.3, 1) 0.5s forwards;
      }

      @keyframes fc-label-in {
        0%   { opacity: 0; letter-spacing: 1px; }
        100% { opacity: 0.6; letter-spacing: 4px; }
      }

      /* ── "Fae" main title — materialises from blur ── */

      .fc-title {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 62px;
        font-weight: 300;
        letter-spacing: 14px;
        /* padding-right compensates the trailing letter-spacing gap */
        padding-right: 14px;
        color: rgba(255, 255, 255, 0.96);
        margin: 0 0 4px;
        opacity: 0;
        text-shadow:
          0 0 60px rgba(180, 168, 196, 0.55),
          0 0 120px rgba(180, 168, 196, 0.2);
        animation: fc-title-in 2.2s cubic-bezier(0.16, 1, 0.3, 1) 1.1s forwards;
      }

      /* Overshoot letter-spacing then settle — gives a premium materialise feel */
      @keyframes fc-title-in {
        0%   { opacity: 0; letter-spacing: 2px;  filter: blur(18px); }
        50%  { opacity: 1; letter-spacing: 18px; filter: blur(0); }
        100% { opacity: 1; letter-spacing: 14px; filter: blur(0); }
      }

      /* ── Thin separator rule ── */

      .fc-rule {
        width: 48px;
        height: 1px;
        background: linear-gradient(90deg, transparent, rgba(180, 168, 196, 0.5), transparent);
        margin: 18px 0;
        opacity: 0;
        animation: fc-fade-up 0.9s ease-out 2.6s forwards;
      }

      /* ── Tagline ── */

      .fc-tagline {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 13px;
        font-style: italic;
        color: rgba(255, 255, 255, 0.42);
        letter-spacing: 0.5px;
        margin: 0 0 38px;
        opacity: 0;
        animation: fc-fade-up 0.9s ease-out 3.1s forwards;
      }

      /* ── Capability pills ── */

      .fc-pills {
        display: flex;
        gap: 10px;
        margin-bottom: 42px;
      }

      .fc-pill {
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 6px 15px;
        background: rgba(180, 168, 196, 0.07);
        border: 1px solid rgba(180, 168, 196, 0.17);
        border-radius: 100px;
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        font-size: 11px;
        color: rgba(255, 255, 255, 0.62);
        opacity: 0;
        -webkit-backdrop-filter: blur(10px);
        backdrop-filter: blur(10px);
      }

      .fc-pill:nth-child(1) { animation: fc-fade-up 0.7s ease-out 3.5s forwards; }
      .fc-pill:nth-child(2) { animation: fc-fade-up 0.7s ease-out 3.9s forwards; }
      .fc-pill:nth-child(3) { animation: fc-fade-up 0.7s ease-out 4.3s forwards; }

      .pill-icon {
        font-size: 12px;
        line-height: 1;
      }

      /* ── Loading bar + "Waking up" ── */

      .fc-loader {
        display: flex;
        flex-direction: column;
        align-items: center;
        gap: 10px;
        opacity: 0;
        animation: fc-fade-up 0.9s ease-out 5.0s forwards;
      }

      .loader-bar {
        width: 96px;
        height: 1px;
        background: rgba(180, 168, 196, 0.13);
        border-radius: 1px;
        overflow: hidden;
        position: relative;
      }

      .loader-fill {
        position: absolute;
        top: 0;
        height: 100%;
        width: 45%;
        background: linear-gradient(90deg, transparent, #B4A8C4, transparent);
        animation: loader-sweep 2.4s ease-in-out infinite;
      }

      @keyframes loader-sweep {
        0%   { left: -50%; }
        100% { left: 110%; }
      }

      .loader-text {
        font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        font-size: 9px;
        font-weight: 500;
        letter-spacing: 2.5px;
        text-transform: uppercase;
        color: rgba(255, 255, 255, 0.27);
        animation: fc-breathe 2.8s ease-in-out infinite;
      }

      /* ── Shared keyframes ── */

      @keyframes fc-fade-up {
        0%   { opacity: 0; transform: translateY(6px); }
        100% { opacity: 1; transform: translateY(0); }
      }

      @keyframes fc-breathe {
        0%, 100% { opacity: 0.27; }
        50%       { opacity: 0.52; }
      }
    </style>
    """

    // MARK: - HTML

    private static let html = """
    <div class="aurora">
      <div class="blob blob-1"></div>
      <div class="blob blob-2"></div>
      <div class="blob blob-3"></div>
    </div>

    <div class="first-contact">
      <div class="fc-label">First Contact</div>
      <div class="fc-title">Fae</div>
      <div class="fc-rule"></div>
      <div class="fc-tagline">Private &nbsp;&middot;&nbsp; Local &nbsp;&middot;&nbsp; Yours.</div>

      <div class="fc-pills">
        <div class="fc-pill">
          <span class="pill-icon">&#127908;</span>
          Listening
        </div>
        <div class="fc-pill">
          <span class="pill-icon">&#129504;</span>
          Thinking
        </div>
        <div class="fc-pill">
          <span class="pill-icon">&#128483;&#65039;</span>
          Speaking
        </div>
      </div>

      <div class="fc-loader">
        <div class="loader-bar">
          <div class="loader-fill"></div>
        </div>
        <div class="loader-text">Waking up</div>
      </div>
    </div>
    """
}
