import Foundation

/// Star Wars-style scrolling intro for Fae's first launch.
///
/// Rendered in the canvas window as HTML + CSS with a perspective
/// crawl animation.
enum IntroCrawl {

    /// Full HTML document for the intro crawl, ready to render in a WKWebView.
    static var fullHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
        \(css)
        </style>
        </head>
        <body>
        \(html)
        </body>
        </html>
        """
    }

    /// HTML body content for the scrolling crawl.
    static var html: String {
        """
        <div class="starfield"></div>
        <div class="crawl-container">
          <div class="crawl-content">
            <p class="crawl-tagline">SAORSA LABS</p>
            <h1>FAE</h1>
            <p>A long time from now, in a world where privacy
            is the most scarce resource...</p>
            <p>One voice companion chose to live entirely on
            your device. No cloud. No surveillance. No corporate
            overlord listening to your conversations.</p>
            <p>She remembers what matters, forgets what doesn't,
            and never phones home.</p>
            <p>She is Fae &mdash; your local, private, sovereign AI
            companion.</p>
            <p class="crawl-tagline">Welcome.</p>
          </div>
        </div>
        """
    }

    /// CSS for the perspective crawl animation and starfield background.
    static var css: String {
        """
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html, body {
          width: 100%; height: 100%;
          background: #000;
          overflow: hidden;
          font-family: -apple-system, BlinkMacSystemFont, sans-serif;
        }
        .starfield {
          position: fixed;
          top: 0; left: 0; right: 0; bottom: 0;
          background: radial-gradient(ellipse at center, #0a0a1a 0%, #000 100%);
        }
        .crawl-container {
          perspective: 300px;
          height: 100vh;
          overflow: hidden;
          display: flex;
          justify-content: center;
          position: relative;
          z-index: 1;
        }
        .crawl-content {
          transform: rotateX(20deg);
          transform-origin: 50% 100%;
          animation: crawl 45s linear forwards;
          text-align: center;
          position: absolute;
          bottom: -100%;
          max-width: 80%;
        }
        .crawl-content h1 {
          font-size: 3em;
          font-weight: 700;
          letter-spacing: 0.3em;
          margin: 20px 0 40px;
          color: rgba(255, 232, 180, 0.95);
        }
        .crawl-content p {
          font-size: 1.2em;
          line-height: 1.8;
          margin: 0 0 24px;
          color: rgba(255, 232, 180, 0.85);
        }
        .crawl-tagline {
          font-size: 0.9em !important;
          letter-spacing: 0.4em;
          color: rgba(255, 232, 180, 0.5) !important;
        }
        @keyframes crawl {
          0% { bottom: -100%; }
          100% { bottom: 200%; }
        }
        """
    }
}
