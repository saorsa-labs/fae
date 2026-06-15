# Orb + Pill UX Redesign — implementation spec (2026-06-15)

> Authored by the main session (designer + reviewer). A worktree-isolated team
> executes this; every phase is gated on **verbatim evidence** (diff-stat,
> `just check-ui-shell` / `just build` tails, live screenshots). Do NOT report a
> phase done without pasting the evidence. (Past dev-agents fabricated reports —
> the reviewer verifies against `git diff`.)

## Goal (owner-locked)

Fae's entire UI becomes **orb + pill**. The pill is the whole conversation
surface and must be **ultra-sleek**.

- **Pill collapsed:** one sleek line showing the **current message** (latest to or
  from Fae), or the live status (Listening / Thinking…) during a turn.
- **Pill click → expands** into a scrollable conversation history + a composer
  input. Click-away / Esc / chevron → collapse.
- **Orb → drag only.** No tap action. Long-press (≥400 ms) still starts talk;
  right-click still opens the context menu.
- **Delete three surfaces entirely:** "Ask Fae", "Messages", "Browser/Data Panel".
- **Rich data → the user's own browser:** Fae writes HTML/JS to a temp file and
  opens it with the OS default browser (`open` / `xdg-open`). No in-app data panel.

Design tokens: DESIGN.md. Gold `#D4A934` (Fae), heather `#B4A8C4` (you), text
`rgba(255,255,255,.92)`, muted `#9A90A8`, surface `rgba(22,20,28,.78)` frosted.
Message text = system serif 13; labels = system sans 11. No emoji, no gradients.

All paths under `native/rust/fae-ui-shell/src/` (Rust orb host) and
`native/macos/Fae/Sources/Fae/` (Swift) unless noted.

---

## Phase 1 — Pill becomes the conversation surface (Rust host)

### 1a. Replace `PILL_HTML` (main.rs ~1117-1142) with this exact design

```html
<!doctype html><html><head><meta charset='utf-8'><style>
:root{color-scheme:dark;
 --bg:rgba(22,20,28,.78);--border:rgba(180,168,196,.22);
 --text:rgba(255,255,255,.92);--muted:#9A90A8;--you:#B4A8C4;--fae:#D4A934;
 --serif:ui-serif,Georgia,'Times New Roman',serif;
 --sans:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:transparent;overflow:hidden;
 font-family:var(--sans);color:var(--text)}
#shell{position:absolute;inset:8px;display:flex;flex-direction:column;
 background:var(--bg);border:1px solid var(--border);border-radius:9999px;
 box-shadow:0 10px 34px rgba(0,0,0,.42);
 -webkit-backdrop-filter:blur(22px) saturate(1.1);backdrop-filter:blur(22px) saturate(1.1);
 opacity:0;transform:translateY(2px);overflow:hidden;
 transition:opacity .22s cubic-bezier(0,0,.2,1),border-radius .26s cubic-bezier(.4,0,.2,1)}
#shell.show{opacity:1;transform:none}
#shell.expanded{border-radius:18px}
#line{display:flex;align-items:center;gap:9px;height:34px;min-height:34px;
 padding:0 15px;cursor:pointer;white-space:nowrap;overflow:hidden}
#shell.expanded #line{display:none}
#dot{width:7px;height:7px;border-radius:50%;flex:none;background:var(--muted);
 transition:background .2s,box-shadow .2s}
#dot.you{background:var(--you)}
#dot.fae{background:var(--fae);box-shadow:0 0 8px rgba(212,169,52,.5)}
#dot.live{animation:pulse 1.3s ease-in-out infinite}
#line.listen #dot{background:#8FB8A2;animation:pulse 1.2s ease-in-out infinite}
#txt{font:13px/1.3 var(--serif);overflow:hidden;text-overflow:ellipsis;flex:1 1 auto}
#line.muted #txt{color:var(--muted);font-family:var(--sans);font-size:12px}
@keyframes pulse{0%,100%{opacity:.45;transform:scale(.82)}50%{opacity:1;transform:scale(1.12)}}
#exp{display:none;flex-direction:column;flex:1 1 auto;min-height:0}
#shell.expanded #exp{display:flex}
#head{display:flex;align-items:center;justify-content:space-between;padding:11px 15px 7px;flex:none}
#head .l{font:11px var(--sans);letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}
#cl{cursor:pointer;color:var(--muted);font-size:14px;line-height:1;padding:2px 6px;border-radius:6px}
#cl:hover{color:var(--text);background:rgba(255,255,255,.06)}
#log{flex:1 1 auto;min-height:0;overflow-y:auto;padding:4px 15px 8px;
 display:flex;flex-direction:column;gap:9px;scroll-behavior:smooth}
#log::-webkit-scrollbar{width:7px}
#log::-webkit-scrollbar-thumb{background:rgba(180,168,196,.22);border-radius:9999px}
.msg{display:flex;gap:9px;align-items:flex-start;animation:rise .2s ease-out}
.msg .d{width:6px;height:6px;border-radius:50%;margin-top:6px;flex:none;background:var(--muted)}
.msg.you .d{background:var(--you)}.msg.fae .d{background:var(--fae)}
.msg .b{font:13px/1.42 var(--serif);white-space:pre-wrap;word-break:break-word}
.msg.you .b{color:#CEC4DC}
@keyframes rise{from{opacity:0;transform:translateY(3px)}to{opacity:1;transform:none}}
#cmp{display:flex;align-items:center;gap:8px;padding:9px 11px 11px;flex:none;
 border-top:1px solid rgba(180,168,196,.14)}
#in{flex:1 1 auto;background:rgba(255,255,255,.04);border:1px solid var(--border);
 border-radius:9999px;padding:8px 13px;color:var(--text);font:13px var(--serif);outline:none}
#in::placeholder{color:var(--muted)}
#in:focus{border-color:rgba(212,169,52,.5)}
#snd{flex:none;width:30px;height:30px;border-radius:50%;border:none;cursor:pointer;
 background:var(--fae);color:#0F1013;font-size:15px;font-weight:600;
 display:flex;align-items:center;justify-content:center;opacity:.5;transition:opacity .15s}
#snd.ready{opacity:1}
</style></head><body>
<div id='shell'>
 <div id='line'><span id='dot'></span><span id='txt'></span></div>
 <div id='exp'>
  <div id='head'><span class='l'>Conversation</span><span id='cl'>⌄</span></div>
  <div id='log'></div>
  <div id='cmp'><input id='in' placeholder='Message Fae…' autocomplete='off'/><button id='snd'>↑</button></div>
 </div>
</div>
<script>(function(){
var shell=document.getElementById('shell'),line=document.getElementById('line'),
 dot=document.getElementById('dot'),txt=document.getElementById('txt'),log=document.getElementById('log'),
 input=document.getElementById('in'),snd=document.getElementById('snd'),cl=document.getElementById('cl');
var messages=[],status=null;
var post=function(o){if(window.ipc&&window.ipc.postMessage)window.ipc.postMessage(JSON.stringify(o));};
function rc(r){return r==='fae'?'fae':((r==='you'||r==='user')?'you':'');}
function renderLine(){
 if(status){line.className=(status.kind||'');dot.className=status.live?'live':'';
  txt.textContent=status.text;line.classList.toggle('muted',status.muted===true);return;}
 var m=messages[messages.length-1];
 if(m){line.className='';dot.className=rc(m.role);txt.textContent=m.text;}
 else{line.className='muted';dot.className='';txt.textContent='Hold ⌥ or click to talk';}
}
function renderLog(){log.innerHTML='';messages.forEach(function(m){
 var e=document.createElement('div');e.className='msg '+rc(m.role);
 var d=document.createElement('span');d.className='d';
 var b=document.createElement('span');b.className='b';b.textContent=m.text;
 e.appendChild(d);e.appendChild(b);log.appendChild(e);});log.scrollTop=log.scrollHeight;}
window.__faeSetMessages=function(a){messages=a||[];shell.classList.add('show');renderLine();
 if(shell.classList.contains('expanded'))renderLog();};
window.__faeSetStatus=function(kind,text,opts){opts=opts||{};
 status=kind?{kind:kind,text:text,live:opts.live===true,muted:opts.muted===true}:null;
 shell.classList.add('show');renderLine();};
window.__faeExpand=function(on){if(on){shell.classList.add('expanded');renderLog();
 setTimeout(function(){input.focus();},30);}else{shell.classList.remove('expanded');input.blur();renderLine();}};
line.addEventListener('click',function(){post({type:'pill_expand'});});
cl.addEventListener('click',function(){post({type:'pill_collapse'});});
input.addEventListener('input',function(){snd.classList.toggle('ready',input.value.trim().length>0);});
function submit(){var t=input.value.trim();if(!t)return;post({type:'send_text',text:t});input.value='';snd.classList.remove('ready');}
snd.addEventListener('click',submit);
input.addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey){e.preventDefault();submit();}
 else if(e.key==='Escape'){post({type:'pill_collapse'});}});
renderLine();
})();</script></body></html>
```

### 1b. Make the pill window interactive + sized for two states

- `PillPanel` (main.rs ~1042): add `expanded: bool`. Define two sizes:
  `COLLAPSED = (360, 52)`, `EXPANDED = (360, 440)` (PhysicalSize).
- `open_pill_panel`: keep transparent/no-decorations/always-on-top. **Remove**
  `with_focused(false)` → allow focus. **Remove** `set_ignore_cursor_events(true)`
  (the pill must be clickable). Use `COLLAPSED` size. Add an **IPC handler**
  identical to `open_messages_panel`'s (clone the `panel_proxy`, forward
  `request.body()` as `UserEvent::PanelAction`). The fn needs the
  `panel_proxy: &EventLoopProxy<UserEvent>` param (thread it from `main`).
- Add `set_pill_expanded(pill, orb_window, expanded)`: set `pill.expanded`,
  `pill.window.set_inner_size(...)`, `position_pill(...)`, evaluate
  `window.__faeExpand(true|false)`, and on expand `pill.window.set_focus()`.

### 1c. Route conversation + status into the pill (replace the status-only `refresh_pill`)

- Add `push_pill_messages(pill, orb_ui)`: serialize `orb_ui.messages` to a JSON
  array of `{role, text}` where role maps `user→"you"`, `fae→"fae"`, else the raw
  role; `evaluate_script("window.__faeSetMessages(<json>)")`. Map roles so the JS
  `rc()` colours match. Call it wherever `ShellCommand::Conversation` and
  `ClearConversation` are handled (apply_bridge_command ~951), and once at startup.
- Rewrite `refresh_pill` to push **status** via `window.__faeSetStatus(kind,text,opts)`
  instead of `__setPill`. Reuse the existing `pill_content` mapping but emit:
  - starting → `('info', "<msg> · NN%", {})`
  - error → `('alert', "Fae needs attention", {})`
  - Listening → `('listen', "Listening — let go to send", {live:true})`
  - Thinking → `('info', "Thinking…" / "Thinking — Ns", {live:true})`
  - Speaking → `('info', "Speaking — tap ⌥ to interrupt", {})`
  - Quiescent first-run → `('hint', "Hold ⌥ or click to talk", {muted:true})`
  - Quiescent idle → **clear status** (`__faeSetStatus(null)`), so the pill shows
    the latest message (or the muted hint if no messages yet).
  Keep the dedupe-by-content guard.
- Status takes priority over the latest message during a turn; when status clears,
  the latest message shows. (The JS already encodes this priority.)

### 1d. Handle pill IPC + collapse-on-focus-loss (event loop)

- In the `UserEvent::PanelAction` / panel-action routing, parse the JSON; for the
  pill add: `pill_expand` → `set_pill_expanded(.., true)`; `pill_collapse` →
  `set_pill_expanded(.., false)`. `send_text` is ALREADY forwarded to Swift via
  `emit_panel_action` — leave that path; it reaches `onSendText → injectText`.
- Add `WindowEvent::Focused(false)` for the pill window → if expanded,
  `set_pill_expanded(.., false)` (click-away collapses).
- Keep `position_pill` following the orb; reposition after every resize.

### 1e. Orb click = drag only

- Remove the short-press pill-pulse (main.rs ~695: the `PressState::Pending`
  release that calls `__pillPulse` / `refresh_pill(hovering)`). A short click does
  nothing now. Keep: drag (move), long-press → `TalkStart`, right-click → menu.
- Delete the now-unused `window.__pillPulse` (it's gone from the new PILL_HTML).

**P1 evidence:** `just check-ui-shell` tail (0 warnings), `just run-dev`, and a
screenshot/log of: collapsed pill showing a message, click→expanded history +
composer, typing a message reaching the pipeline (`injectText` in /tmp/fae-dev.log).

---

## Phase 2 — Delete Ask Fae + Messages + Browser/Data

Per the verified inventory:

- **menu.rs:** remove `MenuAction::{AskFae, ShowMessages, OpenBrowserDataPanel}`
  variants, their `append_item` calls, and ID mappings. Keep all other items.
- **main.rs:** delete `open_messages_panel`, `messages_html`,
  `refresh_messages_panels`, `open_browser_data_panel`, `browser_data_html`, and
  the `MenuAction::{ShowMessages, AskFae, OpenBrowserDataPanel}` handler arms.
  Remove `WebPanelKind::{Messages, BrowserData}` variants and any `match` arms.
  **Keep** `refresh_panel_kind`, `emit_panel_action`, `build_webview_for_window`,
  Settings/Scheduler/Skills panels.
- **protocol.rs:** remove `ShellCommand::ShowMessages`.
- **Swift RustUiShellController.swift:** remove `onAskFae` (var + the
  `case "ask_fae"`). Keep `case "send_text"` (now the pill uses it).
- **Swift FaeApp.swift:** remove the `onAskFae` closure (~264-267). Keep
  `onSendText → faeCore.injectText` (~226-228) — the pill drives it.
- **Verify-then-delete the Swift main conversation window + `InputBarView`:** grep
  every reference to the window `onAskFae` showed (`windowState.showWindow()`,
  `.faeWillFocusInputField`, `InputBarView`). If the window is shown ONLY by
  Ask Fae, remove the window + `InputBarView.swift` and the focus notification.
  If anything else shows it, STOP and report — do not delete.

**P2 evidence:** `just build` 0 errors/0 warnings; `git diff --stat`; grep proving
no dangling refs to the deleted symbols.

---

## Phase 3 — Rich data → user's default browser

- Add a small tool `show_html` (Swift `Tools/`, registered in
  `ToolRegistry.buildDefault()`): args `{ html: string, title?: string }`. Writes
  the HTML to `FaeDirectories.cache/render/<uuid>.html` and opens it with the OS
  default browser (`/usr/bin/open` on macOS; `xdg-open` on Linux via the portable
  path). Returns the file URL. Owner-gated like other tools; no network.
- Add a one-line capability hint in `PersonalityManager.assemblePrompt()` tool
  section: "To show charts/tables/documents/video, generate a self-contained HTML
  page and call `show_html` — it opens in the user's browser."
- This replaces the deleted Browser/Data panel.

**P3 evidence:** unit test for the temp-file write + open-command construction
(don't actually launch a browser in tests); `just build`/`just test` tails.

---

## Phase 4 — Token unification + polish

- Hoist a shared `:root` token block (the one in 1a) and apply to the remaining
  panels (Settings/Scheduler/Skills) so gold is uniformly `#D4A934`, not `#E6C05A`.
- Verify motion/easing matches DESIGN.md. Live-test the whole flow.

**P4 evidence:** before/after screenshots; `just check-ui-shell` + `just build`.

---

## Cross-platform note

The pill is pure HTML/CSS/JS in wry → runs on macOS (WKWebView) and Linux
(WebKitGTK). `backdrop-filter` may no-op on WebKitGTK; the solid
`rgba(22,20,28,.78)` background is the fallback and looks fine opaque. Window
resize + focus + ignore-cursor toggles are tao APIs (portable). Keep the design
working with an opaque background (no transparency dependency for legibility).
