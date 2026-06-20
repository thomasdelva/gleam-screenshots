# gleam_screenshots

Screenshot regression testing for Gleam web UIs, on the **JavaScript target or
the BEAM**.

It renders **raw HTML** with headless Chrome and pixel-diffs the result against a
committed baseline with [odiff](https://github.com/dmtrKovalenko/odiff). Because
it works on complete HTML documents it's view-layer agnostic — use it with
[Lustre](https://hexdocs.pm/lustre/) (pass `element.to_string(view)`), an
[htmx](https://htmx.org) server, or any template. The library never imports
Lustre, and drives Chrome/odiff through the dual-target
[`shellout`](https://hexdocs.pm/shellout/) package, so the same code runs on Node
and on Erlang/OTP. A real regression keeps your build **red** until you
explicitly accept the change; baselines are never silently overwritten.

## Requirements

| Env var      | What                              | Get it                                   |
| ------------ | --------------------------------- | ---------------------------------------- |
| `CHROME_BIN` | a Chrome / Chromium executable    | system Chrome, or Chrome for Testing     |
| `ODIFF_BIN`  | the odiff executable              | `npm i -D odiff-bin` → `node_modules/.bin/odiff` |

## Install

```sh
gleam add gleam_screenshots --dev
npm i -D odiff-bin
```

> Until this is published to Hex, depend on it from git:
> `gleam_screenshots = { git = "https://github.com/thomasdelva/gleam-screenshots", ref = "main" }`

## Usage

Pass a **complete HTML document** string — inline your CSS (or reference assets
relative to the baseline's directory). With Lustre you stringify the view
yourself; with htmx you pass the page your server renders — same call either way:

```gleam
import gleeunit/should
import lustre/element
import lustre/element/html
import screenshot

pub fn home_page_test() {
  let view = html.main([], [html.h1([], [element.text("Andern")])])
  let document =
    "<!doctype html><html><head><style>"
    <> "body { margin: 0; font-family: sans-serif }"
    <> "</style></head><body>"
    <> element.to_string(view)
    <> "</body></html>"

  screenshot.document_matches_baseline(
    document:,
    baseline: "test/screenshots/home",
    size: screenshot.desktop,
    threshold: 0.1,
  )
  |> should.equal(Ok(screenshot.Match))
}
```

Sizes `mobile` (390×844), `tablet` (768×1024) and `desktop` (1280×800) are
provided; build your own with `ScreenSize(width:, height:)`. For finer control,
`capture` (HTML → PNG) and `diff` (PNG vs PNG) are exposed directly.

## Outcomes & accepting changes

`document_matches_baseline` returns `Ok(Match)` on a match, or — both failures, leaving a
proposed `*.new.png` and a `*.diff.png` next to the baseline for review —
`Ok(Mismatch(diff:, proposed:))` when the render differs, or `Ok(Missing(proposed:))`
when there's no baseline yet. Baselines are committed **per platform**
(`home.linux.png`, `home.darwin.png`), since rendering differs across OSes.

When a change is intentional, accept it in one step:

- **Locally:** `SCREENSHOT_ACCEPT=true gleam test` refreshes any baseline that
  drifted past the threshold (and creates missing ones).
- **In CI:** add the `accept-screenshots` label to the PR (see below).

## CI

There's no magic — a screenshot run is just `gleam test` with a browser and odiff
on the runner. Write one job: set up your toolchain, install odiff, point
`CHROME_BIN` / `ODIFF_BIN` at the binaries, and run the suite. On a regression
`gleam test` exits non-zero and leaves `*.new.png` / `*.diff.png` to upload.

Accepting an intentional change is the *same* job: while the `accept-screenshots`
label is on the PR, the run goes into `SCREENSHOT_ACCEPT` mode (the library
refreshes any baseline past the threshold) and a label-gated step commits the
result and pushes it back. Since the library does the adopting, the step is just
plain `git` — no custom action. The label stays on until you remove it, so every
push keeps adopting; drop the label to re-arm the compare guard. That accept path
is the only reason the job needs `contents: write`; a plain compare never pushes.

```yaml
# .github/workflows/screenshots.yml
name: screenshots
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled]
  push:
    branches: [main]
jobs:
  screenshots:
    runs-on: ubuntu-latest
    permissions:
      contents: write # accept mode pushes the refreshed baselines
    steps:
      - uses: actions/checkout@v4
        with: { ref: ${{ github.head_ref || github.ref_name }} }
      - uses: erlef/setup-beam@v1
        with: { otp-version: "27.1.2", gleam-version: "1.14.0", rebar3-version: "3" }
      - uses: actions/setup-node@v4
        with: { node-version: "22" }
      - run: npm ci # or: npm install --no-save odiff-bin
      - run: gleam deps download
      - uses: browser-actions/setup-chrome@v1
        id: setup-chrome
        with: { chrome-version: "131.0.6778.204" }
      # build any assets your HTML references, if any:
      # - run: gleam run -m lustre/dev build --outdir=priv/static
      - run: gleam test
        env:
          SCREENSHOT_ACCEPT: ${{ contains(github.event.pull_request.labels.*.name, 'accept-screenshots') }}
          CHROME_BIN: ${{ steps.setup-chrome.outputs.chrome-path }}
          ODIFF_BIN: node_modules/.bin/odiff
      - if: ${{ success() && contains(github.event.pull_request.labels.*.name, 'accept-screenshots') }}
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git add -A -- test/screenshots
          if ! git diff --cached --quiet; then
            git commit -m "Accept updated screenshots"
            git push origin "HEAD:${{ github.head_ref }}"
          fi
      - if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: screenshot-proposals
          path: |
            **/*.new.png
            **/*.diff.png
          if-no-files-found: ignore
```

Create the `accept-screenshots` label once; while it's on a PR, each run
refreshes the baselines on the branch. Remove it to re-arm the compare guard.
This repo dogfoods the same job via
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

> The accept commit is pushed with the default `GITHUB_TOKEN`, and GitHub does
> not start new workflow runs from `GITHUB_TOKEN` pushes — so an accept push
> won't trigger another run (which is what keeps it from looping). Remove the
> label when you're done; the next push runs the compare and confirms the
> committed baselines are green.

## API

| Function | Purpose |
| --- | --- |
| `document_matches_baseline(document:, baseline:, size:, threshold:)` | Screenshot a complete HTML document → diff vs the platform baseline. |
| `capture(html:, to:, size:, base:)` | Screenshot a complete HTML document to a PNG. |
| `diff(a:, b:, to:, threshold:)` | Pixel-diff two PNGs with odiff. |

## Contributing

Working on the library itself? See [AGENTS.md](AGENTS.md) for commands, how
baselines work, and repo conventions.

## Licence

Apache-2.0
