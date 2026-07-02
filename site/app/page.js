"use client";

const BASE = ""; // served at domain root on Vercel
const BREW = "brew install --cask --no-quarantine ishm6m/doppel/doppel";

function copyBrew(e) {
  const btn = e.currentTarget;
  navigator.clipboard.writeText(BREW).then(() => {
    btn.textContent = "Copied";
    setTimeout(() => (btn.textContent = "Copy"), 1500);
  });
}

export default function Home() {
  return (
    <>
      <nav>
        <div className="wrap">
          <a className="brand" href="#top">
            <img src={`${BASE}/assets/logo-light.png`} alt="" aria-hidden="true" style={{ background: "#000", borderRadius: 5 }} />
            Doppel
          </a>
          <div className="links">
            <a href="#features">Features</a>
            <a href="#privacy">Privacy</a>
            <a href="#how">How it works</a>
            <a href="#install">Install</a>
            <a href="https://github.com/ishm6m/doppel">GitHub</a>
          </div>
        </div>
      </nav>

      {/* ---------------- HERO ---------------- */}
      <header className="hero" id="top">
        <div className="wrap">
          <div className="logo-badge"><img src={`${BASE}/assets/logo-dark.png`} alt="Doppel logo" /></div>
          <p className="eyebrow">Doppel</p>
          <h1>Duplicates,<br />understood.</h1>
          <p className="lead">The Mac app that finds duplicate <em>and near-duplicate</em> documents by reading what&apos;s inside them — not just their name and size. And it does it entirely on your Mac.</p>
          <div className="cta">
            <a className="btn" href="#install">Download for macOS</a>
            <a className="btn secondary" href="#how">See how it works ›</a>
          </div>
          <p className="fineprint">Free &amp; open source · macOS 14 Sonoma or later · 100% offline</p>

          <div className="device">
            <div className="shot">
              <span>App screenshot — Results window</span>
              <small>Placeholder. Drop a capture of the three-column results view here (assets/shot-results.png).</small>
            </div>
          </div>
        </div>
      </header>

      {/* ---------------- FEATURE ROWS ---------------- */}
      <section id="features">
        <div className="wrap">
          <div className="section-head">
            <h2>Not just identical.<br />Actually the same.</h2>
            <p className="lead">Two files can be the same contract with a different date, the same photo re-exported, the same draft saved twice. Doppel sees past the bytes.</p>
          </div>

          <div className="feature-row">
            <div className="copy">
              <h3>Content-aware matching</h3>
              <p>Doppel reads text, PDFs, and Office documents, then compares meaning — not filenames. It surfaces near-duplicates a hash-only tool would miss entirely.</p>
            </div>
            <div className="media">
              <div className="shot"><span>Compare view</span><small>Side-by-side word diff (assets/shot-compare.png)</small></div>
            </div>
          </div>

          <div className="feature-row reverse">
            <div className="copy">
              <h3>Every match, explained</h3>
              <p>No black boxes. Each group tells you <em>why</em> it&apos;s a match and how confident it is — “same contract, changed date” — with a clear confidence score you can trust.</p>
            </div>
            <div className="media">
              <div className="shot"><span>Group card</span><small>Reason + confidence badge (assets/shot-group.png)</small></div>
            </div>
          </div>

          <div className="feature-row">
            <div className="copy">
              <h3>Deletes are always safe</h3>
              <p>Doppel never destroys anything. It <em>suggests</em> a keeper; you confirm. Everything goes to the Trash, and a single ⌘Z brings it right back.</p>
            </div>
            <div className="media">
              <div className="shot"><span>Confirmation sheet</span><small>Multi-select + select-all-but-keeper (assets/shot-delete.png)</small></div>
            </div>
          </div>
        </div>
      </section>

      {/* ---------------- PRIVACY BAND ---------------- */}
      <section className="band-dark" id="privacy">
        <div className="wrap">
          <div className="logo-badge"><img src={`${BASE}/assets/logo-dark.png`} alt="" /></div>
          <h2>Nothing leaves your Mac.</h2>
          <p className="lead">Privacy isn&apos;t a setting in Doppel — it&apos;s the whole point. The app opens <strong>zero</strong> network connections and doesn&apos;t even request permission to. Your files, their names, and their contents never go anywhere.</p>
          <div className="privacy-grid">
            <div className="card">
              <h3>Truly offline</h3>
              <p>No accounts, no cloud, no telemetry. A build-time guard fails the release if any networking code ever sneaks in.</p>
            </div>
            <div className="card">
              <h3>On-device intelligence</h3>
              <p>All analysis runs on Apple Silicon, right on your machine. The smart stuff happens locally or not at all.</p>
            </div>
            <div className="card">
              <h3>Open source</h3>
              <p>MIT licensed and fully auditable. Don&apos;t take our word for it — read every line on GitHub.</p>
            </div>
          </div>
        </div>
      </section>

      {/* ---------------- HOW IT WORKS ---------------- */}
      <section id="how" className="tight">
        <div className="wrap">
          <div className="section-head">
            <h2>Fast, because it&apos;s smart about being slow.</h2>
            <p className="lead">Doppel runs cheap, instant checks first and only reaches for heavy analysis on what&apos;s left. Your time and battery are spent where they matter.</p>
          </div>
          <div className="steps">
            <div className="step">
              <h3>Enumerate</h3>
              <p>Scans your chosen folders. Unchanged files from last time are skipped, never re-read.</p>
            </div>
            <div className="step">
              <h3>Exact match</h3>
              <p>A SHA-256 pass instantly clears byte-identical copies — the easy wins, first.</p>
            </div>
            <div className="step">
              <h3>Near-duplicate</h3>
              <p>MinHash + LSH finds documents that are almost the same, even with edits.</p>
            </div>
            <div className="step">
              <h3>Deep scan</h3>
              <p>Opt-in semantic pass over what&apos;s left — on-device embeddings, never a default.</p>
            </div>
          </div>
        </div>
      </section>

      {/* ---------------- FEATURE GRID ---------------- */}
      <section className="tight">
        <div className="wrap">
          <div className="grid">
            <div className="card"><span className="ic">📄</span><h3>Text &amp; PDF</h3><p>Handles .txt, .md, .docx, and PDF text layers. Scanned PDFs are flagged “needs OCR,” never silently dropped.</p></div>
            <div className="card"><span className="ic">↔️</span><h3>Side-by-side compare</h3><p>A clean word-level diff against the suggested keeper, so you decide with the full picture.</p></div>
            <div className="card"><span className="ic">↩️</span><h3>Undo anything</h3><p>Every removal is a Trash move. Single-level Undo restores instantly if you change your mind.</p></div>
            <div className="card"><span className="ic">⚡</span><h3>Incremental scans</h3><p>Re-scan a huge folder in seconds. Doppel remembers what hasn&apos;t changed.</p></div>
            <div className="card"><span className="ic">🚫</span><h3>“Not duplicates”</h3><p>Mark a group as distinct and it stays that way — it won&apos;t come back to nag you on the next scan.</p></div>
            <div className="card"><span className="ic">🕘</span><h3>Scan history</h3><p>Reopen any past session. Your work is saved and revisitable, all locally.</p></div>
          </div>
        </div>
      </section>

      {/* ---------------- INSTALL ---------------- */}
      <section className="install" id="install">
        <div className="wrap">
          <h2>Get Doppel</h2>
          <p className="lead" style={{ maxWidth: 520, margin: "0 auto" }}>Install with Homebrew.</p>
          <div className="code">
            <code>{BREW}</code>
            <button onClick={copyBrew}>Copy</button>
          </div>
          <p className="note">Or download the <code>.zip</code> from <a href="https://github.com/ishm6m/doppel/releases/latest">GitHub Releases</a>.</p>
        </div>
      </section>

      <footer>
        <div className="wrap">
          <span>Doppel — open-source, offline duplicate finder for macOS. MIT licensed.</span>
          <span>
            <a href="https://github.com/ishm6m/doppel">GitHub</a> ·{" "}
            <a href="https://github.com/ishm6m/doppel/releases/latest">Releases</a> ·{" "}
            <a href="https://github.com/ishm6m/doppel/blob/master/LICENSE">License</a>
          </span>
        </div>
      </footer>
    </>
  );
}
