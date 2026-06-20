# gleam_screenshots

Screenshot regression testing for Gleam web UIs on the **JavaScript target**.

It renders **raw HTML** with headless Chrome and pixel-diffs the result against a
committed baseline with [odiff](https://github.com/dmtrKovalenko/odiff). Because
it works on HTML strings it's view-layer agnostic — use it with
[Lustre](https://hexdocs.pm/lustre/) (pass `element.to_string(view)`), an
[htmx](https://htmx.org) server, or any template. The library never imports
Lustre. A real regression keeps your build **red** until you explicitly accept
the change; baselines are never silently overwritten.

## Requirements

| Env var      | What                              | Get it                                   |
| ------------ | --------------------------------- | ---------------------------------------- |
| `CHROME_BIN` | a Chrome / Chromium executable    | system Chrome, or Chrome for Testing     |
| `ODIFF_BIN`  | the odiff executable              | `npm i -D odiff-bin` → `node_modules/.bin/odiff` |

Template injection also uses the [`linkedom`](https://www.npmjs.com/package/linkedom)
npm package.

## Install

```sh
gleam add gleam_screenshots --dev
npm i -D linkedom odiff-bin
```

> Until this is published to Hex, depend on it from git:
> `gleam_screenshots = { git = "https://github.com/thomasdelva/gleam-screenshots", ref = "main" }`

Add a template that links your real stylesheet and has a mount node, e.g.
`test/screenshot_template.html`:

```html
<!doctype html>
<html>
  <head>
    <link rel="stylesheet" href="../priv/static/app.css" />
  </head>
  <body>
    <div id="app"></div>
  </body>
</html>
```

The `<link>` is resolved relative to the template on disk, so build your CSS
before running the tests.

## Usage

Pass any HTML string. With Lustre you stringify the view yourself; with htmx you
pass the fragment your server renders — same call either way:

```gleam
import gleeunit/should
import lustre/element
import lustre/element/html
import screenshot

const template = "test/screenshot_template.html"

pub fn home_page_test() {
  let view = html.main([], [html.h1([], [element.text("Andern")])])

  screenshot.matches_baseline(
    content: element.to_string(view),
    baseline: "test/screenshots/home",
    options: screenshot.options(template:, selector: "#app")
      |> screenshot.with_size(screenshot.desktop),
  )
  |> should.equal(Ok(screenshot.Match))
}
```

Sizes `mobile` (390×844), `tablet` (768×1024) and `desktop` (1280×800) are
provided; build your own with `ScreenSize(width:, height:)`. For a complete HTML
document (no template) use the lower-level `capture` + `diff` directly.

## Outcomes & accepting changes

`matches_baseline` returns `Ok(Match)` on a match, or — both failures, leaving a
proposed `*.new.png` and a `*.diff.png` next to the baseline for review —
`Ok(Mismatch(diff:, proposed:))` when the render differs, or `Ok(Missing(proposed:))`
when there's no baseline yet. Baselines are committed **per platform**
(`home.linux.png`, `home.darwin.png`), since rendering differs across OSes.

When a change is intentional, accept it in one step:

- **Locally:** `SCREENSHOT_ACCEPT=true gleam test` refreshes every baseline.
- **In CI:** add the `accept-screenshots` label to the PR (see below).

## CI

There's no magic — a screenshot run is just `gleam test` with a browser and odiff
on the runner. Write one job: set up your toolchain, install odiff (and
`linkedom` if you use template injection), point `CHROME_BIN` / `ODIFF_BIN` at
the binaries, and run the suite. On a regression `gleam test` exits non-zero and
leaves `*.new.png` / `*.diff.png` for you to upload.

Accepting an intentional change is the *same* job: adding the
`accept-screenshots` label flips the run into `SCREENSHOT_ACCEPT` mode, and the
composite **`accept` action** commits the refreshed baselines, pushes them back,
and drops the label. The label path is the only reason the job needs write
permissions; a plain compare never pushes.

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
      pull-requests: write # accept mode drops the label
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
      # build the assets your template links, if any:
      # - run: gleam run -m lustre/dev build --outdir=priv/static
      - run: gleam test
        env:
          SCREENSHOT_ACCEPT: ${{ github.event.label.name == 'accept-screenshots' }}
          CHROME_BIN: ${{ steps.setup-chrome.outputs.chrome-path }}
          ODIFF_BIN: node_modules/.bin/odiff
      - if: ${{ success() && github.event.label.name == 'accept-screenshots' }}
        uses: thomasdelva/gleam-screenshots/accept@main
        # with: { paths: test/screenshots }  # scope the accept commit, if you like
      - if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: screenshot-proposals
          path: |
            **/*.new.png
            **/*.diff.png
          if-no-files-found: ignore
```

Create the `accept-screenshots` label once; adding it to a PR refreshes the
baselines on the branch. This repo dogfoods the same job via
[`.github/workflows/ci.yml`](.github/workflows/ci.yml).

> **After accepting, re-run the regression check.** The accept action pushes with
> the default `GITHUB_TOKEN`, and GitHub does not trigger new workflow runs from
> `GITHUB_TOKEN` pushes, so the regression check won't re-run itself — re-run it
> from the Actions tab (the accept commit is already correct). To make it
> self-heal to green automatically, check out with a PAT (`token:`) so the push
> is attributed to a user.

## API

| Function | Purpose |
| --- | --- |
| `matches_baseline(content:, baseline:, options:)` | Render → screenshot → diff vs the platform baseline. |
| `options(template:, selector:)` / `with_size` | Build the config for `matches_baseline`. |
| `capture(html:, to:, size:, base:)` | Screenshot a complete HTML document to a PNG. |
| `capture_in_template(content:, into:, at:, to:, size:)` | Inject a fragment into a template, then screenshot. |
| `render(content:, into:, at:)` | Inject a fragment into a template, returning the combined HTML. |
| `diff(a:, b:, to:, threshold:)` | Pixel-diff two PNGs with odiff. |

## Contributing

Working on the library itself? See [AGENTS.md](AGENTS.md) for commands, how
baselines work, and repo conventions.

## Licence

Apache-2.0
