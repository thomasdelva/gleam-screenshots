# gleam_screenshots

Screenshot regression testing for Gleam web UIs on the **JavaScript target**.

It renders **raw HTML** with headless Chrome and pixel-diffs the result against a
committed baseline with [odiff](https://github.com/dmtrKovalenko/odiff). Because
it works on HTML strings, it's view-layer agnostic — use it with
[Lustre](https://hexdocs.pm/lustre/), an [htmx](https://htmx.org) server that
emits HTML fragments, or any hand-written template. The library itself **does not
depend on Lustre** (Lustre is only a dev-dependency, used by the example test).

A real visual regression keeps your build **red** until a human explicitly
accepts the change — baselines are never silently overwritten.

## How it works

1. Your test produces an HTML string (a Lustre view via `element.to_string`, an
   htmx fragment, whatever).
2. The string is injected into a template HTML file at a CSS selector (so it
   inherits your real stylesheet), and headless Chrome screenshots it at a chosen
   viewport size.
3. The PNG is pixel-diffed against the committed baseline for the current
   platform (`<name>.<platform>.png`).
4. On a match the test passes. On a mismatch (or a missing baseline) the test
   **fails** and a proposed screenshot + a visual diff are written for review.

## Requirements

The library shells out to external tools, located via environment variables:

| Env var      | What                              | Get it                                   |
| ------------ | --------------------------------- | ---------------------------------------- |
| `CHROME_BIN` | a Chrome / Chromium executable    | system Chrome, or Chrome for Testing     |
| `ODIFF_BIN`  | the odiff executable              | `npm i -D odiff-bin` → `node_modules/.bin/odiff` |

The template helpers also use the [`linkedom`](https://www.npmjs.com/package/linkedom)
npm package (`npm i -D linkedom`).

> Renders use Chrome's `--headless=old` so the CSS viewport matches the
> requested `ScreenSize` exactly (`--headless=new` reserves a ~87px region, so a
> `100vh` element renders short). On a Chrome build that has dropped old
> headless, set `SCREENSHOT_HEADLESS=new` and regenerate baselines.

## Install

```sh
gleam add gleam_screenshots --dev
npm i -D linkedom odiff-bin
```

> Until this is published to Hex, depend on it from git in `gleam.toml`:
>
> ```toml
> [dev-dependencies]
> gleam_screenshots = { git = "https://github.com/thomasdelva/gleam-screenshots", ref = "main" }
> ```

Add a template that links your real stylesheet and has a mount node, e.g.
`test/screenshot_template.html`:

```html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
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

### With Lustre

The library never imports Lustre — you stringify the view yourself:

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
    options: screenshot.options(template:, selector: "#app"),
  )
  |> should.equal(Ok(screenshot.Match))
}
```

### With htmx / raw HTML

Exactly the same call — just pass the HTML string your server renders:

```gleam
pub fn nav_fragment_test() {
  let fragment = render_nav(current: "/study")  // your own HTML-producing fn

  screenshot.matches_baseline(
    content: fragment,
    baseline: "test/screenshots/nav",
    options: screenshot.options(template:, selector: "#app")
      |> screenshot.with_size(screenshot.desktop),
  )
  |> should.equal(Ok(screenshot.Match))
}
```

If you already have a **complete** HTML document (no template needed), use the
lower-level `screenshot.capture(html:, to:, size:, base:)` and
`screenshot.diff(a:, b:, to:, threshold:)` directly.

### Screen sizes

`mobile` (390×844), `tablet` (768×1024) and `desktop` (1280×800) are provided;
construct your own with `ScreenSize(width:, height:)` and set it via
`with_size`. Each test can pick its own size.

## The regression loop

`matches_baseline` returns:

- `Ok(Match)` — render matches the baseline. ✅
- `Ok(Mismatch(diff:, proposed:))` — render differs. ❌ The diff image and the
  proposed new screenshot are written next to the baseline.
- `Ok(Missing(proposed:))` — no baseline yet for this platform. ❌ The render is
  written so you can promote it.

Because the value carries the `diff`/`proposed` paths, a failing
`should.equal(Ok(screenshot.Match))` prints exactly where to look.

**Baselines are per-platform** (`home.linux.png`, `home.darwin.png`): pixel
rendering differs across rasterisation stacks, so commit one baseline per OS you
develop/CI on. The first run on a new platform produces a `Missing` and proposes
a baseline to commit.

### Accepting a new baseline

When a change is intentional, accept it in one step.

**Locally — one command** refreshes every baseline from the current render:

```sh
SCREENSHOT_ACCEPT=true gleam test
```

**In CI — one click**: add the `accept-screenshots` label to the PR (see CI
below). The accept workflow re-renders, commits the refreshed baselines to the
branch, and removes the label; the next run goes green.

You can also promote already-written proposals without re-rendering:

```gleam
screenshot.accept_all("test/screenshots")   // promotes every *.new.png
screenshot.accept(baseline: "test/screenshots/home")  // or just one
```

Then commit the updated `*.png` baselines.

## CI

Copy both workflow templates into `.github/workflows/`:

- [`templates/screenshot-regression.yml`](templates/screenshot-regression.yml) —
  runs your tests; on a visual regression it **fails the build** and uploads the
  proposed screenshots + diffs as an artifact for review. It never overwrites
  the baseline, so a regression can't heal itself green.
- [`templates/screenshot-accept.yml`](templates/screenshot-accept.yml) — the
  **one-click accept**. Create an `accept-screenshots` label once; adding it to a
  PR refreshes the baselines on the branch (or run the workflow manually).

This repo dogfoods both: see [`.github/workflows/`](.github/workflows/).

## API

| Function | Purpose |
| --- | --- |
| `matches_baseline(content:, baseline:, options:)` | The test helper: render → screenshot → diff vs the platform baseline. |
| `options(template:, selector:)` / `with_size` / `with_threshold` | Build the config for `matches_baseline`. |
| `capture(html:, to:, size:, base:)` | Screenshot a complete HTML document to a PNG. |
| `capture_in_template(content:, into:, at:, to:, size:)` | Inject a fragment into a template, then screenshot. |
| `render(content:, into:, at:)` | Inject a fragment into a template, returning the combined HTML. |
| `diff(a:, b:, to:, threshold:)` | Pixel-diff two PNGs with odiff. |
| `accept(baseline:)` / `accept_all(dir:)` | Promote proposed screenshots to baselines. |

## Licence

Apache-2.0
