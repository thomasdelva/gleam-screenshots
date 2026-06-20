//// Project-agnostic screenshot regression testing for Gleam web UIs, on the
//// JavaScript target or the BEAM.
////
//// It renders **raw HTML** with headless Chrome and pixel-diffs the result
//// against a committed baseline with [odiff](https://github.com/dmtrKovalenko/odiff).
//// Because it works on HTML strings, it is view-layer agnostic: use it with
//// [Lustre](https://hexdocs.pm/lustre/) (pass `lustre/element.to_string(view)`),
//// an htmx server that emits HTML fragments, or any hand-written template.
////
//// Shelling out to Chrome and odiff is done through per-target FFI, so the same
//// code runs on Node and on Erlang/OTP. The template helpers (`render`,
//// `capture_in_template`, `matches_baseline`) additionally use the JavaScript
//// `linkedom` package, so they are JS-only; on the BEAM, render a full page and
//// use `capture` / `document_matches_baseline`.
////
//// ## Binaries
////
//// External tools are located through environment variables so the same code
//// runs locally and in CI:
////
//// - `CHROME_BIN` — a Chrome / Chromium executable.
//// - `ODIFF_BIN`  — the odiff executable (`npm i -D odiff-bin` installs one at
////   `node_modules/.bin/odiff`).
////
//// The template helpers additionally need the `linkedom` npm package
//// (`npm i -D linkedom`).
////
//// Renders use Chrome's `--headless=old` so the CSS viewport matches the
//// requested `ScreenSize` exactly. On a Chrome build that has dropped old
//// headless, set `SCREENSHOT_HEADLESS=new` and regenerate baselines.
////
//// odiff's per-pixel colour threshold defaults to `0.1`; override it for a
//// whole run with `SCREENSHOT_THRESHOLD` (e.g. `0.2`) to tame cross-environment
//// rendering jitter without touching tests or baselines.
////
//// ## The regression loop
////
//// `matches_baseline` is designed so a real visual regression keeps the build
//// **red** until a human explicitly accepts the change. On a mismatch it writes
//// a *proposed* screenshot next to the baseline (`<baseline>.<platform>.new.png`)
//// and a visual diff (`<baseline>.<platform>.diff.png`) — but it never
//// overwrites the baseline itself.
////
//// To accept intentional changes, re-run the suite with `SCREENSHOT_ACCEPT=true`
//// (`SCREENSHOT_ACCEPT=true gleam test`): every baseline is refreshed from the
//// current render and the suite passes. That single command is what the
//// one-click CI accept job runs.

import envoy
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import screenshot/dom
import screenshot/exec
import simplifile

// MARK: Types

/// A browser viewport size in CSS pixels.
pub type ScreenSize {
  ScreenSize(width: Int, height: Int)
}

/// iPhone 14 viewport — a common mobile baseline.
pub const mobile = ScreenSize(width: 390, height: 844)

/// iPad portrait viewport.
pub const tablet = ScreenSize(width: 768, height: 1024)

/// A typical laptop viewport.
pub const desktop = ScreenSize(width: 1280, height: 800)

/// Anything that can go wrong while capturing or diffing.
pub type Error {
  /// A required environment variable (`CHROME_BIN` / `ODIFF_BIN`) is unset.
  MissingBinary(env_var: String)
  /// Headless Chrome exited non-zero. `output` is its captured stderr.
  BrowserFailed(status: Int, output: String)
  /// odiff exited with an unexpected status. `output` is its captured stderr.
  DiffFailed(status: Int, output: String)
  /// The template file could not be read.
  TemplateNotFound(path: String)
  /// The template had no element matching the mount selector.
  SelectorNotFound(selector: String)
  /// A file could not be written (render scratch file, proposal, baseline...).
  WriteFailed(path: String)
}

/// The result of comparing a render against its baseline.
pub type Outcome {
  /// The render matches the committed baseline. Pass.
  Match
  /// The render differs. `diff` and `proposed` are the on-disk paths to the
  /// visual diff and the proposed new screenshot, kept for review. Fail.
  Mismatch(diff: String, proposed: String)
  /// No baseline exists yet for this platform. `proposed` is the freshly
  /// captured render, kept so it can be promoted to the baseline. Fail.
  Missing(proposed: String)
}

/// Configuration shared by the baseline helper: which template to mount into,
/// where to mount, the viewport, and the odiff per-pixel colour threshold.
pub type Options {
  Options(
    template: String,
    selector: String,
    size: ScreenSize,
    threshold: Float,
  )
}

/// Default options for a template: mount at the given `selector`, render at
/// `mobile` size, compare with odiff's default per-pixel threshold (`0.1`).
pub fn options(template template: String, selector selector: String) -> Options {
  Options(template:, selector:, size: mobile, threshold: 0.1)
}

/// Override the viewport size on an `Options`. Override other fields with a
/// record update, e.g. `Options(..opts, threshold: 0.2)`.
pub fn with_size(options: Options, size: ScreenSize) -> Options {
  Options(..options, size:)
}

// MARK: Capture

/// Screenshot a complete HTML document string into `path` (a PNG).
///
/// The document is written to a scratch file inside `base` so any **relative**
/// URLs it references (stylesheets, images) resolve against that directory
/// under the `file://` URL Chrome loads. The scratch file name is derived from
/// `path`, so independent captures running concurrently never collide.
///
/// Use this for the raw-HTML / htmx case where you already have a full page.
/// For mounting a fragment into a shared template, see `capture_in_template`.
pub fn capture(
  html html: String,
  to path: String,
  size size: ScreenSize,
  base base: String,
) -> Result(Nil, Error) {
  use base_abs <- result.try(absolute(base))
  let render_abs = base_abs <> "/.screenshot_render." <> slug(path) <> ".html"
  use _ <- result.try(
    simplifile.write(to: render_abs, contents: html)
    |> result.replace_error(WriteFailed(render_abs)),
  )
  let outcome = run_chrome(render_abs, path, size)
  // The scratch render is only needed while Chrome loads it; remove it so it
  // doesn't linger in (and get committed from) the caller's working tree.
  let _ = simplifile.delete(render_abs)
  outcome
}

@target(javascript)
/// Inject `content` into the HTML `template` file at the first element matching
/// `selector`, then screenshot the combined page into `path`.
///
/// The scratch render is written next to the template, so the template's
/// relative `<link rel="stylesheet">` / `<img>` paths resolve. Requires
/// `linkedom`, so this is JavaScript-only; on the BEAM use `capture` with a
/// complete HTML document.
pub fn capture_in_template(
  content content: String,
  into template: String,
  at selector: String,
  to path: String,
  size size: ScreenSize,
) -> Result(Nil, Error) {
  use combined <- result.try(render(content, template, selector))
  capture(html: combined, to: path, size:, base: directory_of(template))
}

@target(javascript)
/// Read the HTML `template` file and inject `content` at the first element
/// matching `selector` (the same shape as `lustre.start`'s mount point),
/// returning the combined document. Requires `linkedom`, so this is
/// JavaScript-only.
pub fn render(
  content content: String,
  into template: String,
  at selector: String,
) -> Result(String, Error) {
  use template_html <- result.try(
    simplifile.read(from: template)
    |> result.replace_error(TemplateNotFound(template)),
  )
  dom.mount_into_template(template: template_html, selector:, content:)
  |> result.replace_error(SelectorNotFound(selector))
}

// MARK: Diff

/// Pixel-diff two PNGs with odiff. Returns `Ok(True)` when they match,
/// `Ok(False)` when they differ (and writes the visual diff to `diff_path`).
///
/// `--antialiasing` is always passed so sub-pixel font-rendering differences
/// don't trip the comparison; `threshold` is odiff's per-pixel colour
/// threshold (0.0–1.0).
pub fn diff(
  a a: String,
  b b: String,
  to diff_path: String,
  threshold threshold: Float,
) -> Result(Bool, Error) {
  use odiff <- result.try(env("ODIFF_BIN"))

  let args = [
    "--antialiasing",
    "--threshold=" <> float.to_string(threshold),
    a,
    b,
    diff_path,
  ]

  // odiff exits 0 when the images match and 22 when they differ; anything else
  // (including -1, which `exec.run` reports when odiff couldn't be started) is a
  // genuine failure.
  case exec.run(odiff, args) {
    exec.Run(status: 0, ..) -> Ok(True)
    exec.Run(status: 22, ..) -> Ok(False)
    exec.Run(status:, output:) -> Error(DiffFailed(status:, output:))
  }
}

// MARK: Baseline regression helper

@target(javascript)
/// Render `content` into `options.template` at `options.selector`, screenshot
/// it, and compare against the committed baseline for the current platform.
///
/// `baseline` is a stem (e.g. `"test/screenshots/home"`); the helper appends
/// `.<platform>.png` (e.g. `home.linux.png`). Each platform keeps its own
/// baseline because pixel rendering differs across rasterisation stacks.
///
/// This **never** overwrites the baseline. On a mismatch it returns
/// `Mismatch(diff, proposed)` and leaves both files on disk for review; on a
/// missing baseline it returns `Missing(proposed)`. Both are failures — the
/// build stays red until you accept the new render (`SCREENSHOT_ACCEPT=true`).
/// On a match it returns `Match` and cleans up any stale proposal/diff so a
/// green run leaves no noise.
///
/// In a test, assert on the result so the failure print surfaces the diff path:
///
/// ```gleam
/// screenshot.matches_baseline(content: html, baseline: stem, options: opts)
/// |> should.equal(Ok(screenshot.Match))
/// ```
pub fn matches_baseline(
  content content: String,
  baseline baseline: String,
  options options: Options,
) -> Result(Outcome, Error) {
  check_baseline(baseline, options.threshold, fn(proposed) {
    capture_in_template(
      content:,
      into: options.template,
      at: options.selector,
      to: proposed,
      size: options.size,
    )
  })
}

/// Like `matches_baseline`, but for a **complete HTML document** instead of a
/// fragment + template — no `linkedom`, so it runs on every target. This is the
/// entry point for BEAM / htmx servers: pass the full page your server renders
/// (inline its CSS, or reference assets relative to `baseline`'s directory).
///
/// The accept / mismatch / missing behaviour is identical to `matches_baseline`.
pub fn document_matches_baseline(
  document document: String,
  baseline baseline: String,
  size size: ScreenSize,
  threshold threshold: Float,
) -> Result(Outcome, Error) {
  check_baseline(baseline, threshold, fn(proposed) {
    capture(html: document, to: proposed, size:, base: directory_of(proposed))
  })
}

/// The shared accept / compare / missing loop behind both baseline helpers.
/// `capture_to` renders the subject into the given proposal path (via a template
/// or a full document); everything after that — accept mode, the odiff compare,
/// keeping proposals/diffs on failure, cleaning up on a match — is identical.
fn check_baseline(
  baseline: String,
  threshold: Float,
  capture_to: fn(String) -> Result(Nil, Error),
) -> Result(Outcome, Error) {
  let plat = dom.platform()
  let golden = baseline <> "." <> plat <> ".png"
  let proposed = baseline <> "." <> plat <> ".new.png"
  let diff_path = baseline <> "." <> plat <> ".diff.png"

  let _ = simplifile.create_directory_all(directory_of(proposed))
  use _ <- result.try(capture_to(proposed))

  case accepting() {
    // One-click accept mode (`SCREENSHOT_ACCEPT=true`): adopt the current
    // render as the baseline and pass. Re-running the suite once in this mode
    // refreshes every baseline — the basis of the one-click CI accept job.
    True -> {
      use _ <- result.try(
        simplifile.copy_file(at: proposed, to: golden)
        |> result.replace_error(WriteFailed(golden)),
      )
      let _ = simplifile.delete(proposed)
      let _ = simplifile.delete(diff_path)
      Ok(Match)
    }
    False ->
      case simplifile.is_file(golden) {
        Ok(True) -> {
          use matched <- result.try(diff(
            a: golden,
            b: proposed,
            to: diff_path,
            threshold: threshold_for(threshold),
          ))
          case matched {
            True -> {
              // A clean run leaves no proposal/diff lying around.
              let _ = simplifile.delete(proposed)
              let _ = simplifile.delete(diff_path)
              Ok(Match)
            }
            False -> Ok(Mismatch(diff: diff_path, proposed:))
          }
        }
        _ -> Ok(Missing(proposed:))
      }
  }
}

/// Whether the suite is running in accept mode (`SCREENSHOT_ACCEPT=true`), in
/// which `matches_baseline` adopts the current render as the baseline instead
/// of comparing against it.
fn accepting() -> Bool {
  case envoy.get("SCREENSHOT_ACCEPT") {
    Ok("true") | Ok("1") -> True
    _ -> False
  }
}

/// The effective odiff threshold. `SCREENSHOT_THRESHOLD` (a decimal like
/// `0.2`) overrides the per-test `default` for the whole run when set — handy
/// for loosening tolerance in CI without editing tests or baselines.
fn threshold_for(default: Float) -> Float {
  case envoy.get("SCREENSHOT_THRESHOLD") {
    Ok(value) -> result.unwrap(float.parse(value), default)
    Error(_) -> default
  }
}

// MARK: Internals

fn run_chrome(
  render_abs: String,
  path: String,
  size: ScreenSize,
) -> Result(Nil, Error) {
  use chrome <- result.try(env("CHROME_BIN"))

  let args = [
    // `old` headless makes the CSS viewport equal the requested window size.
    // `new` headless reserves a phantom ~87px top-chrome region, so a 100vh
    // element renders short of the screenshot height. Overridable via
    // SCREENSHOT_HEADLESS for Chrome builds that have dropped old headless.
    "--headless=" <> headless_mode(),
    "--disable-gpu",
    "--no-sandbox",
    "--hide-scrollbars",
    // Pin DPI so renders are deterministic across machines.
    "--force-device-scale-factor=1",
    "--screenshot=" <> path,
    "--window-size="
      <> int.to_string(size.width)
      <> ","
      <> int.to_string(size.height),
    "file://" <> render_abs,
  ]

  case exec.run(chrome, args) {
    exec.Run(status: 0, ..) -> Ok(Nil)
    exec.Run(status:, output:) -> Error(BrowserFailed(status:, output:))
  }
}

fn env(name: String) -> Result(String, Error) {
  envoy.get(name) |> result.replace_error(MissingBinary(name))
}

/// The Chrome headless mode, `old` by default (exact-viewport screenshots).
/// Set `SCREENSHOT_HEADLESS=new` on Chrome builds without old headless.
fn headless_mode() -> String {
  case envoy.get("SCREENSHOT_HEADLESS") {
    Ok("new") -> "new"
    _ -> "old"
  }
}

/// Resolve `path` to an absolute path (Chrome's `file://` URL needs one).
fn absolute(path: String) -> Result(String, Error) {
  case string.starts_with(path, "/") {
    True -> Ok(path)
    False -> {
      use cwd <- result.try(
        simplifile.current_directory()
        |> result.replace_error(WriteFailed(path)),
      )
      Ok(cwd <> "/" <> path)
    }
  }
}

fn directory_of(path: String) -> String {
  let segments = string.split(path, on: "/")
  case list.length(segments) {
    0 | 1 -> "."
    n -> segments |> list.take(n - 1) |> string.join("/")
  }
}

/// A filesystem-safe token derived from an output path, used to give each
/// capture its own scratch render file (so concurrent tests don't clobber one
/// shared name).
fn slug(path: String) -> String {
  path
  |> string.replace("/", "_")
  |> string.replace("\\", "_")
  |> string.replace(":", "_")
  |> string.replace(".", "_")
}
