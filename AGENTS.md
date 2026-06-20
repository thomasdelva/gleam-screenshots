# AGENTS.md

Operational notes for AI agents working **in this repository**. For using the
library in another project, see [README.md](README.md) instead.

`gleam_screenshots` is a Gleam (JavaScript target) library that screenshots raw
HTML with headless Chrome and pixel-diffs it against committed baselines with
odiff. The public API lives in `src/screenshot.gleam`.

## Commands

```sh
gleam build                 # compile
gleam format src test       # format (CI runs `gleam format --check src test`)
gleam test                  # run the suite
```

CI enforces `gleam format --check`, so always format before committing.

## Running the screenshot tests

The screenshot tests need external binaries, found via env vars. **Without
them, the screenshot tests silently skip** (only the pure tests run), so set
them when you intend to actually exercise rendering:

```sh
export CHROME_BIN=/path/to/chrome      # or Chrome for Testing
export ODIFF_BIN=node_modules/.bin/odiff
npm install                            # provides linkedom + odiff-bin
gleam test
```

- `linkedom` (npm) is imported by `src/screenshot/dom.ffi.mjs` for template
  injection; `odiff-bin` provides the diff binary.
- Renders use `--headless=old` (exact viewport). Override with
  `SCREENSHOT_HEADLESS=new` only if your Chrome dropped old headless — and
  regenerate baselines if you do.
- `SCREENSHOT_THRESHOLD=0.2` loosens odiff's per-pixel tolerance for the whole
  run (default `0.1`); set it as a job `env` in CI.

## Baselines

- Committed baselines are `test/screenshots/<name>.<platform>.png`, one **per
  platform** (`uname`/`process.platform`: `linux`, `darwin`, ...). The committed
  set here is `linux` only.
- `*.new.png` (proposals) and `*.diff.png` (visual diffs) are transient and
  **gitignored** — never commit them.
- Renders are font/environment-sensitive. Shape/colour/layout fixtures match
  across machines; **text-bearing** fixtures (`card`, `lustre`, `prose_*`) can
  differ if fonts differ. A mismatch there usually means "regenerate the
  baseline on this platform", not a code bug.

### Regenerating / accepting baselines

```sh
SCREENSHOT_ACCEPT=true gleam test     # adopt current renders as baselines, then pass
```

Only commit baselines for the platform you actually rendered on — do not
hand-edit or overwrite another platform's `*.png`. In CI, accepting is a
one-click `accept-screenshots` label that re-runs the screenshots job in accept
mode (see `.github/workflows/ci.yml`). That push uses `GITHUB_TOKEN`, which does
not re-trigger workflows, so re-run the regression check afterwards (or wire a
PAT push) to refresh its status.

## Layout & conventions

| Path | Role |
| --- | --- |
| `src/screenshot.gleam` | Public API: `capture`, `document_matches_baseline` (any target), `capture_in_template`, `render`, `matches_baseline` (JS-only template path), `diff`. |
| `src/screenshot/exec.gleam` + `exec.ffi.mjs` + `src/screenshot_ffi.erl` | OS-facing per-target FFI so the library runs on both targets: `run` (an executable — Chrome, odiff — via Node `spawnSync` / an Erlang port) and `platform`. |
| `src/screenshot/dom.gleam` + `dom.ffi.mjs` | JS-only FFI: template injection (linkedom). |
| `test/gleam_screenshots_test.gleam` | Suite + living documentation of features. |
| `test/fixtures/` | `template.html` + `styles.css` the tests render. |
| `accept/action.yml` | Composite action for the accept step: after a `SCREENSHOT_ACCEPT` run, commit + push the refreshed baselines and drop the label. |
| `.github/workflows/ci.yml` | This repo's own self-contained CI (screenshots + format); the screenshots job folds in the label-gated accept, dogfooding the `accept` action. |

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
