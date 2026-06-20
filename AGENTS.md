# AGENTS.md

Operational notes for AI agents working **in this repository**. For using the
library in another project, see [README.md](README.md) instead.

`gleam_screenshots` is a **dual-target** Gleam library (JavaScript + the BEAM)
that screenshots raw HTML with headless Chrome and pixel-diffs it against
committed baselines with odiff. The public API lives in `src/screenshot.gleam`.

## Commands

```sh
gleam build                 # compile
gleam format src test       # format (CI runs `gleam format --check src test`)
gleam test                  # run the suite
```

CI enforces `gleam format --check`, so always format before committing.

## Running the screenshot tests

The screenshot tests need external binaries, found via env vars. **Without
them, every screenshot test silently skips** (the suite is all rendering tests),
so set them when you intend to actually exercise rendering:

```sh
export CHROME_BIN=/path/to/chrome-headless-shell
export ODIFF_BIN=node_modules/.bin/odiff
npm install                            # provides odiff-bin
# Get chrome-headless-shell with:
#   npx @puppeteer/browsers install chrome-headless-shell@<version>
gleam test                             # default target; CI also runs both --target erlang/javascript
```

- `odiff-bin` (npm) provides the diff binary; the suite has no JavaScript-only
  code, so it runs identically on both targets.
- **`CHROME_BIN` must be `chrome-headless-shell`**, not full Chrome: it sizes the
  viewport to `--window-size` exactly (full Chrome's `--headless=new` leaves a
  letterbox band — the module doc has the why), so `run_chrome` passes no
  `--headless` flag. It renders WebGL via SwiftShader, covering `with_webgl` too.
- WebGL/settle (`with_webgl`, `with_settle`) are opt-in `Options`, off by
  default. `with_webgl` swaps `--disable-gpu` for the ANGLE/SwiftShader flags;
  `with_settle` adds `--virtual-time-budget`. Assembly is `gpu_args`/`settle_args`
  beside `run_chrome`.
- `SCREENSHOT_THRESHOLD=0.2` loosens odiff's per-pixel tolerance for the whole
  run (default `0.1`); set it as a job `env` in CI.

## Baselines

- Committed baselines are `test/screenshots/<name>.<platform>.png`, one **per
  platform** (`os:type`/`process.platform`: `linux`, `darwin`, ...). The committed
  set here is `linux` only.
- `*.new.png` (proposals) and `*.diff.png` (visual diffs) are transient and
  **gitignored** — never commit them.
- Renders are font/environment-sensitive. Shape/colour/layout fixtures match
  across machines; **text-bearing** fixtures (`card`, `lustre`, `prose_*`) can
  differ if fonts differ. A mismatch there usually means "regenerate the
  baseline on this platform", not a code bug.

### Regenerating / accepting baselines

```sh
SCREENSHOT_ACCEPT=true gleam test     # adopt drifted/missing renders as baselines, then pass
```

Only commit baselines for the platform you actually rendered on — do not
hand-edit or overwrite another platform's `*.png`. In CI, accepting is the
`accept-screenshots` label: while it's on a PR, each run renders in accept mode
and a plain `git` step commits whatever the library refreshed (see
`.github/workflows/ci.yml`). That push uses `GITHUB_TOKEN`, which does not
re-trigger workflows, so it can't loop; remove the label to re-arm the compare.

## Layout & conventions

| Path | Role |
| --- | --- |
| `src/screenshot.gleam` | Public API (all dual-target): `capture`, `document_matches_baseline`, `diff`. Executables run via the `shellout` dependency. |
| `src/screenshot.ffi.mjs` + `src/screenshot_ffi.erl` | Per-target FFI for host `platform()` detection only (Node `process.platform` / Erlang `os:type`). |
| `test/gleam_screenshots_test.gleam` | Suite + living documentation of features. |
| `test/fixtures/styles.css` | The stylesheet the tests inline into a complete HTML document. |
| `.github/workflows/ci.yml` | This repo's own self-contained CI: one `gleam` job (format check plus the screenshot suite on both targets) that also runs the label-gated accept as a plain `git` commit step. |

- **Keep `src/` free of Lustre.** Lustre is a dev-dependency only (used by one
  example test); the library must stay view-layer agnostic and operate on HTML
  strings. Don't add it to `[dependencies]`.
- Errors are a typed `Error` union; prefer extending it over returning strings.
- Doc comments describe current behaviour, not history. When you change
  behaviour, update the relevant `///` docs, the README, and this file in the
  same change rather than narrating the change in prose.
- Temp render files are namespaced per output path (parallel-safe); preserve
  that if you touch `capture*`.

## Don't commit

`build/`, `node_modules/`, `.envrc`, `.screenshot_render.*.html`, `*.new.png`,
`*.diff.png` (all already in `.gitignore`).
