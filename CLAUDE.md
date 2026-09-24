# ComfyBar - native macOS menu-bar monitor and controller for a local ComfyUI

Menu-bar only (LSUIElement, no Dock icon). Swift / SwiftUI panel in an AppKit NSStatusItem +
NSPopover. Bundle id `com.amritus.comfybar`, team 3A3L2C6DFB, Release signed with
"Developer ID Application" (hardened runtime, timestamped). xcodegen `project.yml` (the
.xcodeproj is generated and gitignored). Deployment target macOS 14.

## STANDING RULES (for anyone - human or agent - working on this repo)
- **R1** Only this folder is ours. Never modify `~/ComfyUI` (code, nodes, models, settings,
  input) or any other project that drives the same ComfyUI.
- **R2** Never bind ComfyUI to 0.0.0.0 and never pass `--listen`. `LaunchGuard` enforces it
  (also refuses `--port`, `--tls*`, `--enable-cors*` in extra args, and non-loopback hosts).
- **R3** Hands off the live ComfyUI on 8188: only READ it (GET routes, a listening socket
  under ComfyBar's OWN client id). Test every control against a second instance the app
  starts on a spare port (8199) with scratch `--temp/--user/--output/--input-directory` and
  `--database-url sqlite:///:memory:`. **ComfyUI rmtree's its temp dir on start and exit
  (main.py:488-491, 531, 616) - a second instance sharing ~/ComfyUI/temp would wipe the live
  one's temp files.** The automation hook refuses every mutating command on 8188.
- **R4** Read before you build; cite file:line (docs/GROUNDING.md).
- **R5** No silent numbers: every figure in the panel shows its source; unverifiable figures
  are not shown (GPU busy %, live memory-pressure level - see GROUNDING 1.3).
- **R6** Calibration = model-free EmptyImage -> ColorTransfer graph (`Core/Calibration.swift`),
  never on 8188; its one output file lands in `<output>/comfybar_calibration/`.
- **R7** Before AND after every build/launch: `./scripts/cleanup.sh` (pkill -9 of the app's
  own executable path `ComfyBar.app/Contents/MacOS/ComfyBar`, sleep 2, confirms zero - it no
  longer matches every command line containing "ComfyBar"). Stop any scratch ComfyUI you
  started yourself. Validate on a RELEASE build, launched.
- **R8** Preserve timestamps on copies (cp -p / rsync -a / ditto). Strip ANSI/CR from any
  terminal output quoted in reports.

## NEVER open a websocket under another client's clientId
Measured on a scratch instance (8199): connecting with an existing clientId evicts that client's socket
(server.py:273-276); the evicted client (e.g. the ComfyUI page) receives nothing further,
even after ours closes. There is no API to tell a socketless client (e.g. a render pipeline) from one
with a socket. ComfyBar only ever connects as itself.

## The icon - source of truth is assets/
The maintainer's mark, chosen 2026-09-24 ("2f equal margins": an open C with a B inside):
scale and rasterise only - never redraw, re-proportion or recolour it.
- `assets/ComfyBar-2f-nest-balanced-menubar.svg` - the glyph (100x100, currentColor). Its two
  path strings and stroke widths are copied verbatim into `Core/Mark.swift`;
  `MarkTests.testPathsAreVerbatimFromSourceSVG` fails if the two drift apart.
- `assets/ComfyBar-2f-nest-balanced-appicon.svg` - the app icon (1024, mint C #6FE3C1, cream
  B #F4F1E8 on a dark rounded square). `./scripts/build-icon.sh` renders
  `Sources/ComfyBar/Assets.xcassets/AppIcon.appiconset` from it (10 PNGs, 16-1024 px, each
  rendered at its own size by rsvg-convert). Re-run it only if the SVG changes.
- `assets/ComfyBar logo 2f equal margins.png` - the sheet he approved (right-hand mark).
- Menu bar: the C carries the status colour (and progress along the C when running/queued);
  the B is stroked in NSColor.labelColor at draw time so it follows the menu bar's light/dark
  appearance (a template image cannot also hold colour - NSImage.isTemplate docs).
- After changing the icon, Launch Services may show a stale generic icon for the running app
  until it re-registers the bundle; relaunching fixes it.

## Where progress comes from
1. ComfyUI "progress" websocket messages - only for prompts with NO client_id (broadcast,
   execution.py:736-739 + server.py:1385-1388) or ComfyBar's own calibration job.
2. The sampler tqdm bar in ComfyUI's console buffer, `GET /internal/logs/raw` (read-only;
   /internal is not a stable API - re-verify on ComfyUI updates).
3. Otherwise "not visible", with the reason on screen.

## Layout
- `Sources/ComfyBar/Core` - pure logic, compiled into the hostless unit tests too:
  payload parsing, tqdm parser, attribution, state machine, launch guard, confirmations.
- `Sources/ComfyBar/System` - Mach/sysctl/libproc figures, lsof port probe, memory pressure.
- `Sources/ComfyBar/Control/ServerController.swift` - Start/Stop/Restart (SIGINT -> SIGTERM -> SIGKILL).
- `Sources/ComfyBar/App` - Monitor (poll loop), Actions (every control), Notifier, Automation.
- `Sources/ComfyBar/UI` - status item, glyph renderer, panel, Settings, Debug.
- `Tests/ComfyBarTests` - unit tests on payloads recorded from a real ComfyUI 0.34.0 (`Fixtures/`, personal names removed).

## Repository
- `origin` = https://github.com/AmritusG/comfybar (PUBLIC). Local `main` tracks it. Commit
  as `AmritusG <165056603+AmritusG@users.noreply.github.com>` (set in this repo's git config).
- `dev` = AmritusG/comfybar-dev (PRIVATE): the pre-release history, including test data and
  paths that must not be published. Local branch `dev-archive` tracks it. Never push it to
  `origin`.

## Build / test / run
```
./scripts/cleanup.sh && ./scripts/build.sh && ./scripts/cleanup.sh   # -> ./ComfyBar.app (Release, Developer ID)
./scripts/test.sh                                                     # hostless unit tests
open ComfyBar.app
```
Test automation: launch with `--args -ComfyBarAutomationDir <existing dir> -port 8199
-extraArgs '"--cpu ..."'` (the extra-args value must be plist-quoted because it starts with
`--`), then send commands with `scripts/cbctl.swift` (compile with swiftc). The hook turns on
only from that launch argument (never from a saved preference); the event log mirrors to
`<dir>/events.log`, and `state <name>` / `renderglyphs <subdir>` write only inside `<dir>`.
Launch-argument settings live in NSArgumentDomain; Settings never persists a value that is
unchanged, so they are not saved by accident.

## Release (maintainer)
```
./scripts/cleanup.sh && ./scripts/build.sh && ./scripts/cleanup.sh   # Developer ID signed
./scripts/check-release.sh        # read-only pre-flight: signing, runtime, tree, personal data
NOTARY_PROFILE=amritus-notary ./scripts/notarize.sh   # maintainer's keychain profile (see the script header)
NOTARY_PROFILE=amritus-notary ./scripts/make-dmg.sh   # signed, notarised, stapled DMG + .sha256 in build/
./scripts/release.sh --yes        # tag + GitHub release (publishes!) - bump MARKETING_VERSION first
# v0.1.0 released 2026-09-24: https://github.com/AmritusG/comfybar/releases/tag/v0.1.0
```
Contributors without the Developer ID get ad-hoc signed builds automatically (scripts/signing.sh).
