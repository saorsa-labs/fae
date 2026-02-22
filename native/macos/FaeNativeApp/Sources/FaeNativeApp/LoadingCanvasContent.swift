import Foundation

/// Generates rich HTML content for the Canvas during model loading and after.
///
/// Two phases:
/// 1. **Crawl** (`crawlExperience`) — cinematic Star Wars-style intro explaining
///    what's happening while models load. Runs for ~120s.
/// 2. **Ready** (`readyExperience`) — clean FAQ page with expandable sections
///    covering security, architecture, privacy, and permissions. Pushed to canvas
///    when `isPipelineReady` becomes `true`.
///
/// All animations are pure CSS — no JavaScript required.
enum LoadingCanvasContent {

    // MARK: - Public API

    /// Star Wars-style loading crawl — push this when model loading begins.
    /// - Parameters:
    ///   - ramGB: Total physical RAM in GB (auto-detected if nil).
    ///   - modelName: Display name for the LLM model being loaded.
    static func crawlExperience(ramGB: Int? = nil, modelName: String? = nil) -> String {
        let ram = ramGB ?? Self.systemRAMInGB()
        let model = modelName ?? "Qwen 8B"
        return "\(crawlCSS)\n\(introOverlay)\n\(titleCard)\n\(crawlContent(ramGB: ram, modelName: model))"
    }

    /// Clean interactive FAQ — push this when the pipeline is ready.
    static func readyExperience() -> String {
        "\(readyCSS)\n\(readyContent)"
    }

    /// Legacy compatibility — same as `crawlExperience()`.
    static func fullExperience() -> String { crawlExperience() }

    // MARK: - System Info

    /// Detect system RAM in whole GB.
    private static func systemRAMInGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    // MARK: - Crawl CSS

    private static let crawlCSS = """
    <style>
      /* ── Reset canvas wrapper for full-bleed experience ── */
      body {
        padding: 0 !important;
        overflow: hidden;
        background: transparent !important;
      }

      /* ── Starfield background ── */
      body::before {
        content: '';
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        background:
          radial-gradient(1px 1px at 20% 30%, rgba(255,255,255,0.3), transparent),
          radial-gradient(1px 1px at 40% 70%, rgba(255,255,255,0.2), transparent),
          radial-gradient(1px 1px at 60% 20%, rgba(255,255,255,0.25), transparent),
          radial-gradient(1px 1px at 80% 50%, rgba(255,255,255,0.15), transparent),
          radial-gradient(1px 1px at 10% 80%, rgba(255,255,255,0.2), transparent),
          radial-gradient(1px 1px at 50% 10%, rgba(255,255,255,0.3), transparent),
          radial-gradient(1px 1px at 70% 90%, rgba(255,255,255,0.18), transparent),
          radial-gradient(1px 1px at 90% 40%, rgba(255,255,255,0.22), transparent),
          radial-gradient(1px 1px at 30% 60%, rgba(255,255,255,0.15), transparent),
          radial-gradient(1px 1px at 15% 45%, rgba(255,255,255,0.2), transparent),
          radial-gradient(1px 1px at 85% 15%, rgba(255,255,255,0.18), transparent),
          radial-gradient(1px 1px at 55% 85%, rgba(255,255,255,0.22), transparent);
        pointer-events: none;
        z-index: 0;
      }

      /* ── Intro text ("Not so long ago…") ── */
      .intro-overlay {
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        display: flex;
        align-items: center;
        justify-content: center;
        text-align: center;
        z-index: 20;
        pointer-events: none;
      }

      .intro-text {
        color: #5BA3D9;
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 15px;
        font-style: italic;
        line-height: 2.2;
        opacity: 0;
        animation: intro-fade 5.5s ease-in-out 0.5s forwards;
      }

      @keyframes intro-fade {
        0%   { opacity: 0; }
        18%  { opacity: 1; }
        72%  { opacity: 1; }
        100% { opacity: 0; }
      }

      /* ── Title card ("F A E") ── */
      .title-overlay {
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        display: flex;
        flex-direction: column;
        align-items: center;
        justify-content: center;
        z-index: 15;
        pointer-events: none;
      }

      .title-main {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 42px;
        font-weight: 300;
        letter-spacing: 16px;
        color: #B4A8C4;
        margin: 0;
        opacity: 0;
        animation: title-zoom 7s ease-out 5s forwards;
      }

      .title-sub {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 12px;
        font-weight: 300;
        letter-spacing: 4px;
        color: rgba(255,255,255,0.45);
        margin-top: 10px;
        text-transform: uppercase;
        opacity: 0;
        animation: title-zoom 7s ease-out 5.3s forwards;
      }

      @keyframes title-zoom {
        0%   { opacity: 0; transform: scale(0.15); }
        22%  { opacity: 1; transform: scale(1.0); }
        78%  { opacity: 1; transform: scale(1.0); }
        100% { opacity: 0; transform: scale(3.0); }
      }

      /* ── Crawl viewport (smooth scroll with fade-out) ── */
      .crawl-viewport {
        position: fixed;
        top: 0; left: 0; right: 0; bottom: 0;
        overflow: hidden;
        z-index: 5;
        /* Fade text out at top — evokes the Star Wars "vanishing into distance" */
        -webkit-mask-image: linear-gradient(to bottom, transparent 0%, black 18%, black 100%);
        mask-image: linear-gradient(to bottom, transparent 0%, black 18%, black 100%);
      }

      .crawl {
        position: absolute;
        left: 8%;
        right: 8%;
        top: 100%;
        text-align: center;
        animation: crawl-scroll 120s linear 11s forwards;
      }

      @keyframes crawl-scroll {
        0%   { top: 100%; }
        100% { top: -450%; }
      }

      /* ── Crawl typography ── */
      .crawl p {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 15px;
        line-height: 1.85;
        color: rgba(255,255,255,0.9);
        margin: 0 0 22px;
      }

      .crawl .section-icon {
        font-size: 32px;
        display: block;
        margin: 36px 0 6px;
      }

      .crawl h3 {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        color: #B4A8C4;
        font-size: 15px;
        font-weight: 400;
        letter-spacing: 5px;
        text-transform: uppercase;
        margin: 0 0 12px;
      }

      .crawl .highlight {
        color: #B4A8C4;
        font-style: italic;
      }

      .crawl .tech-note {
        font-size: 11px;
        color: rgba(255,255,255,0.35);
        font-style: italic;
        margin: 2px 0 24px;
      }

      .crawl .divider {
        border: none;
        border-top: 1px solid rgba(180, 168, 196, 0.25);
        margin: 40px auto;
        width: 50%;
      }

      /* ── Honest box ── */
      .honest-box {
        background: rgba(180, 168, 196, 0.06);
        border: 1px solid rgba(180, 168, 196, 0.12);
        border-radius: 14px;
        padding: 18px 20px;
        text-align: left;
        margin: 24px 8px;
      }

      .honest-box p {
        font-size: 13px;
        text-align: left;
        margin: 0 0 8px;
        line-height: 1.7;
      }

      .honest-box p:last-child { margin-bottom: 0; }

      .honest-title {
        color: #B4A8C4;
        font-weight: 500;
        font-size: 14px !important;
        margin-bottom: 12px !important;
      }

      .honest-box .bullet {
        color: rgba(255,255,255,0.6);
        padding-left: 6px;
      }

      .honest-box strong {
        color: #B4A8C4;
        font-weight: 500;
      }

      /* ── Permission items ── */
      .perm-list {
        text-align: left;
        margin: 16px 8px;
      }

      .perm-item {
        display: flex;
        gap: 10px;
        margin: 12px 0;
        font-size: 13px;
        line-height: 1.6;
      }

      .perm-icon {
        flex-shrink: 0;
        font-size: 16px;
        margin-top: 1px;
      }

      .perm-text {
        color: rgba(255,255,255,0.75);
      }

      .perm-label {
        color: #B4A8C4;
        font-weight: 500;
      }

      /* ── Ending ── */
      .ending {
        margin-top: 50px;
        font-size: 16px;
        color: #B4A8C4;
        font-style: italic;
        line-height: 2;
      }

      .ending-small {
        margin-top: 10px;
        font-size: 12px;
        color: rgba(255,255,255,0.35);
        font-style: normal;
      }
    </style>
    """

    // MARK: - Intro Overlay

    private static let introOverlay = """
    <div class="intro-overlay">
      <div class="intro-text">
        Not so long ago,<br>
        on the computer right in front of you&hellip;
      </div>
    </div>
    """

    // MARK: - Title Card

    private static let titleCard = """
    <div class="title-overlay">
      <div class="title-main">F A E</div>
      <div class="title-sub">First Light</div>
    </div>
    """

    // MARK: - The Crawl (dynamic)

    private static func crawlContent(ramGB: Int, modelName: String) -> String {
    """
    <div class="crawl-viewport">
      <div class="crawl">

        <p>
          Fae is waking up. She&rsquo;s loading the<br>
          pieces she needs to understand you,<br>
          think for herself, and talk back &mdash;<br>
          all running privately on <span class="highlight">your</span> computer.
        </p>

        <p>Here&rsquo;s what&rsquo;s happening right now&hellip;</p>

        <div class="section-icon">\u{1F3A4}</div>
        <h3>Listening</h3>
        <p>
          Fae is loading her speech recognition<br>
          engine. This lets her understand what<br>
          you say, turning your voice into words<br>
          she can read and think about.
        </p>
        <div class="tech-note">Parakeet &mdash; a compact, fast speech model</div>

        <div class="section-icon">\u{1F9E0}</div>
        <h3>Thinking</h3>
        <p>
          This is the big one. Fae is loading her<br>
          brain &mdash; a language model that lets her<br>
          understand what you mean, reason through<br>
          problems, and form thoughtful responses.
        </p>
        <p>
          Your Mac has <span class="highlight">\(ramGB) GB</span> of RAM,<br>
          so Fae is loading the <span class="highlight">\(modelName)</span><br>
          model &mdash; the best brain that fits<br>
          comfortably in your machine&rsquo;s memory.
        </p>
        <p>
          This part takes the longest because<br>
          her brain is the biggest component.
        </p>
        <div class="tech-note">\(modelName) &mdash; runs entirely on your Mac</div>

        <div class="section-icon">\u{1F5E3}\u{FE0F}</div>
        <h3>Speaking</h3>
        <p>
          Finally, Fae loads her voice. This turns<br>
          her thoughts into natural speech, giving<br>
          her a voice that&rsquo;s warm, clear, and<br>
          uniquely hers.
        </p>
        <div class="tech-note">Kokoro TTS &mdash; British English, warm tone</div>

        <div class="divider"></div>

        <div class="section-icon">\u{1F52E}</div>
        <h3>Getting Smarter</h3>
        <p>
          Fae&rsquo;s brain is already pretty good,<br>
          but it will get <span class="highlight">much better, fast</span>.<br>
          AI models are improving at a stunning<br>
          pace &mdash; and because Fae runs locally,<br>
          each upgrade drops right in.
        </p>
        <p>
          As better models become available,<br>
          Fae will think deeper, understand more,<br>
          and respond more naturally &mdash; all<br>
          without sending your data anywhere.
        </p>

        <div class="divider"></div>

        <div class="section-icon">\u{1F310}</div>
        <h3>The Fae</h3>
        <p>
          Right now, your Fae works alone.<br>
          But she won&rsquo;t always have to.
        </p>
        <p>
          We&rsquo;re building a <span class="highlight">global, private
          network</span> called <strong>The Fae</strong> &mdash;<br>
          where individual Fae companions can<br>
          find friends, seek collaboration, and<br>
          increase their power exponentially.
        </p>
        <p>
          Imagine your Fae connecting with<br>
          others around the world &mdash; sharing<br>
          knowledge, coordinating tasks, and<br>
          helping each other &mdash; all through<br>
          an encrypted, decentralised network<br>
          with <span class="highlight">no central authority</span>.
        </p>
        <p>
          No company owns The Fae. No server<br>
          sees your data. Every connection is<br>
          quantum-resistant and peer-to-peer.<br>
          Your Fae stays yours. Always.
        </p>
        <div class="tech-note">
          Powered by x0x &mdash; agent-to-agent gossip protocol<br>
          <a href="https://the-fae.com" style="color: #B4A8C4;">the-fae.com</a>
        </div>

        <div class="divider"></div>

        <div class="section-icon">\u{1F3D7}\u{FE0F}</div>
        <h3>How Fae Is Built</h3>
        <p>
          Fae is built differently from other<br>
          AI assistants. She has a<br>
          <span class="highlight">protected core</span> &mdash; like a spine &mdash;<br>
          that keeps her safe and reliable.
        </p>
        <p>
          This core handles your privacy, your<br>
          memories, and her ability to recover<br>
          if something goes wrong. It can never<br>
          be changed &mdash; not even by Fae herself.
        </p>
        <p>
          On top of that spine, Fae has a layer<br>
          she <span class="highlight">can</span> grow and change: her skills.<br>
          She can learn new abilities, customise<br>
          how she works for you, and even write<br>
          her own improvements.
        </p>
        <p>
          Think of it like a house: the foundation<br>
          and walls are permanent, but you can<br>
          rearrange the furniture and add<br>
          decorations however you like.
        </p>

        <div class="honest-box">
          <p class="honest-title">\u{1F6E1}\u{FE0F} Safety Net</p>
          <p>If anything ever goes wrong, Fae has a
          built-in <strong>Rescue Mode</strong>. She can
          diagnose problems, roll back changes, and
          get herself running again &mdash; without
          losing your memories or data.</p>
          <p>This safety net is part of her protected
          core and cannot be disabled.</p>
        </div>

        <div class="divider"></div>

        <div class="section-icon">\u{1F512}</div>
        <h3>Your Privacy</h3>
        <p>
          Everything you just saw being loaded?<br>
          It all runs right here on your Mac.<br>
          Your conversations <span class="highlight">never</span> leave<br>
          this computer. No cloud. No servers.<br>
          No eavesdropping. Ever.
        </p>
        <p>
          Fae lives inside macOS&rsquo;s App Sandbox &mdash;<br>
          she can only access what you<br>
          explicitly allow.
        </p>

        <div class="honest-box">
          <p class="honest-title">\u{1F91D} Brutal Honesty</p>
          <p>We believe you deserve the truth:</p>
          <p class="bullet">&bull; <strong>Prompt injection</strong> is a real, industry-wide
          challenge. Bad actors can try to trick AI systems through
          cleverly crafted text. We actively defend against this,
          but no system is perfect.</p>
          <p class="bullet">&bull; Your data stays on <strong>your device</strong>.
          That&rsquo;s not a marketing line &mdash; it&rsquo;s our architecture.</p>
          <p class="bullet">&bull; We will always tell you what Fae can and
          cannot do. No hype. No hand-waving.</p>
        </div>

        <div class="divider"></div>

        <div class="section-icon">\u{1F4F1}</div>
        <h3>Why Permissions?</h3>
        <p>
          Each permission you grant makes Fae<br>
          more helpful. None are required.<br>
          All are revocable. You&rsquo;re always<br>
          in control.
        </p>

        <div class="perm-list">
          <div class="perm-item">
            <span class="perm-icon">\u{1F4C5}</span>
            <span class="perm-text"><span class="perm-label">Calendar</span> &mdash;
            So Fae can remind you about meetings, help you
            schedule, and keep your day organised.</span>
          </div>
          <div class="perm-item">
            <span class="perm-icon">\u{1F465}</span>
            <span class="perm-text"><span class="perm-label">Contacts</span> &mdash;
            So Fae knows who you&rsquo;re talking about and can
            help you stay connected with the people who matter.</span>
          </div>
          <div class="perm-item">
            <span class="perm-icon">\u{2709}\u{FE0F}</span>
            <span class="perm-text"><span class="perm-label">Mail</span> &mdash;
            So Fae can draft messages, manage your inbox,
            and save you time on correspondence.</span>
          </div>
          <div class="perm-item">
            <span class="perm-icon">\u{1F3A4}</span>
            <span class="perm-text"><span class="perm-label">Microphone</span> &mdash;
            So Fae can hear you speak. This is how you&rsquo;ll
            have natural conversations with her.</span>
          </div>
        </div>

        <p class="ending">
          Almost there&hellip;<br>
          Fae will be ready soon.
        </p>
        <p class="ending-small">
          She&rsquo;s worth the wait.
        </p>

      </div>
    </div>
    """
    }

    // MARK: - Ready Experience CSS

    private static let readyCSS = """
    <style>
      body {
        padding: 0 !important;
        margin: 0;
        overflow-y: auto;
        overflow-x: hidden;
        background: transparent !important;
      }

      .ready-page {
        padding: 28px 20px 40px;
        opacity: 0;
        animation: fade-in 0.8s ease-out 0.1s forwards;
      }

      @keyframes fade-in {
        to { opacity: 1; }
      }

      .ready-header {
        text-align: center;
        margin-bottom: 28px;
      }

      .ready-icon {
        font-size: 36px;
        display: block;
        margin-bottom: 8px;
      }

      .ready-title {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 20px;
        font-weight: 300;
        letter-spacing: 6px;
        color: #B4A8C4;
        text-transform: uppercase;
        margin: 0;
      }

      .ready-subtitle {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 13px;
        color: rgba(255,255,255,0.5);
        margin-top: 6px;
      }

      .section-label {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 11px;
        font-weight: 400;
        letter-spacing: 3px;
        text-transform: uppercase;
        color: rgba(255,255,255,0.3);
        margin: 24px 0 10px;
        padding-left: 4px;
      }

      /* ── Expandable FAQ ── */
      details {
        background: rgba(180, 168, 196, 0.04);
        border: 1px solid rgba(180, 168, 196, 0.1);
        border-radius: 12px;
        margin: 8px 0;
        overflow: hidden;
        transition: border-color 0.3s ease;
      }

      details[open] {
        border-color: rgba(180, 168, 196, 0.2);
      }

      summary {
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 14px;
        color: #B4A8C4;
        padding: 14px 18px;
        cursor: pointer;
        list-style: none;
        display: flex;
        justify-content: space-between;
        align-items: center;
      }

      summary::-webkit-details-marker { display: none; }

      summary::after {
        content: '+';
        font-size: 18px;
        color: rgba(180, 168, 196, 0.5);
        font-weight: 300;
        transition: transform 0.3s ease;
      }

      details[open] summary::after {
        transform: rotate(45deg);
      }

      .faq-body {
        padding: 0 18px 16px;
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 13px;
        line-height: 1.7;
        color: rgba(255,255,255,0.75);
      }

      .faq-body p { margin: 0 0 8px; }
      .faq-body p:last-child { margin-bottom: 0; }
      .faq-body strong { color: #B4A8C4; font-weight: 500; }

      .faq-body code {
        font-family: 'SF Mono', Monaco, monospace;
        font-size: 0.82em;
        background: rgba(255,255,255,0.07);
        border-radius: 4px;
        padding: 1px 5px;
      }

      .ready-footer {
        text-align: center;
        margin-top: 28px;
        font-family: 'Iowan Old Style', 'Palatino Linotype', Palatino, Georgia, serif;
        font-size: 12px;
        color: rgba(255,255,255,0.3);
        line-height: 1.8;
      }
    </style>
    """

    // MARK: - Ready Page Content

    private static let readyContent = """
    <div class="ready-page">

      <div class="ready-header">
        <span class="ready-icon">\u{2728}</span>
        <h1 class="ready-title">Fae Is Ready</h1>
        <p class="ready-subtitle">Say hello, or explore what makes her tick.</p>
      </div>

      <div class="section-label">Security &amp; Privacy</div>

      <details>
        <summary>\u{1F512} What about security?</summary>
        <div class="faq-body">
          <p>Fae runs entirely on your Mac inside the <strong>macOS App Sandbox</strong>.
          This means she physically cannot access files, folders, or
          services you haven&rsquo;t granted permission for.</p>
          <p>All AI processing happens locally &mdash; your conversations,
          memories, and personal data never travel to any server.
          There is no cloud component.</p>
          <p>We take a defence-in-depth approach to prompt injection
          and other adversarial techniques. While no AI system can
          claim to be 100% immune, we continuously improve our
          safeguards and are transparent about the limitations.</p>
        </div>
      </details>

      <details>
        <summary>\u{1F4E6} Where does my data go?</summary>
        <div class="faq-body">
          <p>Nowhere. Seriously.</p>
          <p>Your conversations are stored in a local database
          on your Mac. Your voice is processed by the on-device
          speech model. Your calendar, contacts, and mail are
          accessed through macOS APIs and never copied elsewhere.</p>
          <p>Fae has <strong>no telemetry, no analytics, and no
          phone-home capability</strong>. What happens on your Mac
          stays on your Mac.</p>
        </div>
      </details>

      <details>
        <summary>\u{1F9E0} Why does the brain take so long?</summary>
        <div class="faq-body">
          <p>Fae&rsquo;s language model has billions of parameters &mdash;
          that&rsquo;s a lot of knowledge packed into about 16 GB
          of data. Loading it into memory takes time, especially
          the first time.</p>
          <p>The upside? Once loaded, Fae thinks fast and works
          completely offline. No internet needed. No API calls.
          No waiting for a server on the other side of the world.</p>
          <p>Subsequent launches are faster because the model
          files are cached locally.</p>
        </div>
      </details>

      <div class="section-label">Architecture</div>

      <details>
        <summary>\u{1F3D7}\u{FE0F} How is Fae built?</summary>
        <div class="faq-body">
          <p>Fae uses a <strong>four-layer architecture</strong> designed
          for safety and growth:</p>
          <p><strong>1. Protected Kernel</strong> &mdash; The immutable safety spine.
          Handles privacy, permissions, memory integrity, secrets,
          and recovery. Cannot be changed, even by Fae herself.</p>
          <p><strong>2. Guarded Layer</strong> &mdash; Extensible systems like her
          AI engine, canvas, and skill runtime. Human-reviewed but
          designed to grow.</p>
          <p><strong>3. Self-Authored Layer</strong> &mdash; Skills, prompts, and
          preferences that Fae can create and customise for you.
          This is where personalisation lives.</p>
          <p><strong>4. Ephemeral State</strong> &mdash; Temporary working memory,
          logs, and session data that comes and goes.</p>
          <p>The design rule: behaviour lives in the self-authored layer
          unless it&rsquo;s required for safety or recovery.</p>
        </div>
      </details>

      <details>
        <summary>\u{1F6E1}\u{FE0F} What is the Protected Kernel?</summary>
        <div class="faq-body">
          <p>The Protected Kernel is the part of Fae that <strong>can never
          be self-modified</strong>. It&rsquo;s like the foundation of a house &mdash;
          you can redecorate every room, but the foundation stays solid.</p>
          <p>It protects:</p>
          <p>&bull; <strong>Your privacy</strong> &mdash; permission policy and capability gates</p>
          <p>&bull; <strong>Your memories</strong> &mdash; database schema, backups, and integrity checks</p>
          <p>&bull; <strong>Your secrets</strong> &mdash; credentials and keychain access</p>
          <p>&bull; <strong>Recovery</strong> &mdash; the ability to diagnose and repair problems</p>
          <p>&bull; <strong>Updates</strong> &mdash; safe self-update with rollback capability</p>
          <p>Fae may <em>propose</em> changes to her kernel, but she cannot
          apply them without a human-authored review.</p>
        </div>
      </details>

      <details>
        <summary>\u{2728} Can Fae improve herself?</summary>
        <div class="faq-body">
          <p>Yes &mdash; within carefully designed boundaries.</p>
          <p>Fae can <strong>create new skills</strong>, adjust her personality
          and communication style, learn your preferences, and
          write her own improvements to how she works for you.</p>
          <p>What she <em>cannot</em> do is change her safety systems,
          bypass permissions, or modify her recovery mechanisms.
          This gives you the benefits of a self-improving assistant
          without the risk of self-corruption.</p>
          <p>Every self-authored change goes through a validation
          pipeline: generate, validate, test, promote. If something
          fails, it&rsquo;s automatically rolled back to the last
          known-good state.</p>
        </div>
      </details>

      <details>
        <summary>\u{1F198} What is Rescue Mode?</summary>
        <div class="faq-body">
          <p>Rescue Mode is Fae&rsquo;s built-in safety net. If something
          goes wrong &mdash; a corrupted skill, a failed update, or
          repeated crashes &mdash; Fae can enter a minimal recovery mode.</p>
          <p>In Rescue Mode, she can:</p>
          <p>&bull; Diagnose what went wrong</p>
          <p>&bull; Roll back broken changes</p>
          <p>&bull; Restore skills from backup</p>
          <p>&bull; Get herself running again</p>
          <p>All without losing your memories, conversations, or data.
          The safety net is part of the Protected Kernel and
          <strong>cannot be disabled</strong>.</p>
        </div>
      </details>

      <div class="section-label">Permissions</div>

      <details>
        <summary>\u{1F4F1} Why does Fae ask for permissions?</summary>
        <div class="faq-body">
          <p>Each permission makes Fae more capable, but
          <strong>none are required</strong>. She works without any of them &mdash;
          she just can&rsquo;t help with calendar, contacts, or mail
          tasks until you grant access.</p>
          <p><strong>Calendar</strong> &mdash; reminders, scheduling, daily briefings.</p>
          <p><strong>Contacts</strong> &mdash; knowing who you&rsquo;re talking about,
          staying connected with people who matter.</p>
          <p><strong>Mail</strong> &mdash; drafting messages, managing your inbox.</p>
          <p><strong>Microphone</strong> &mdash; hearing you speak for natural conversation.</p>
          <p>All permissions flow through macOS&rsquo;s own privacy system.
          You can revoke any of them at any time in
          System Settings &rarr; Privacy &amp; Security.</p>
        </div>
      </details>

      <details>
        <summary>\u{1F504} Can I change permissions later?</summary>
        <div class="faq-body">
          <p>Absolutely. Permissions can be granted or revoked at any
          time through macOS System Settings &rarr; Privacy &amp; Security.
          Fae will gracefully adapt &mdash; she&rsquo;ll simply have fewer
          capabilities without the revoked permissions.</p>
          <p>You can also control Fae&rsquo;s tool access directly in
          Settings &rarr; Tools within the app.</p>
        </div>
      </details>

      <div class="ready-footer">
        Close this window any time.<br>
        Fae is listening and ready to chat.
      </div>

    </div>
    """
}
