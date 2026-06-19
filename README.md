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

The workflows are **reusable** — reference them with `uses:`, no copy-paste. Add
a caller to your repo's `.github/workflows/`:

```yaml
# .github/workflows/screenshots.yml
name: screenshots
on:
  pull_request:
  push:
    branches: [main]
jobs:
  screenshots:
    uses: thomasdelva/gleam-screenshots/.github/workflows/screenshots.yml@main
    with:
      # command that builds the assets your template links — omit if none
      build-command: gleam run -m lustre/dev build --outdir=priv/static
```

On a regression it **fails the build** and uploads the proposals + diffs as an
artifact; it never overwrites the baseline. For the **one-click accept**, add a
second caller of the same workflow with `accept: true`, gated on a label and
granted write access:

```yaml
# .github/workflows/screenshots-accept.yml
name: screenshots-accept
on:
  pull_request:
    types: [labeled]
jobs:
  accept:
    if: github.event.label.name == 'accept-screenshots'
    permissions:
      contents: write       # push the refreshed baselines
      pull-requests: write  # drop the label afterwards
    uses: thomasdelva/gleam-screenshots/.github/workflows/screenshots.yml@main
    with:
      accept: true
      build-command: gleam run -m lustre/dev build --outdir=priv/static
```

`accept` defaults to `false`, so the regular caller never pushes and needs no
permissions. Create the `accept-screenshots` label once; adding it to a PR
refreshes the baselines on the branch. The workflow also takes optional
`gleam-version`, `otp-version`, `node-version` and `chrome-version` inputs. This
repo dogfoods both callers via [`.github/workflows/`](.github/workflows/).

> **After accepting, re-run the regression check.** The accept job pushes with
> the default `GITHUB_TOKEN`, and GitHub does not trigger new workflow runs from
> `GITHUB_TOKEN` pushes, so the regression check won't re-run itself — re-run it
> from the Actions tab (the accept commit is already correct). To make it
> self-heal to green automatically, push from the accept job with a PAT
> (`actions/checkout` with a `token:` secret) instead.

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
