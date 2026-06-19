//// Project-agnostic screenshot regression testing for Gleam web UIs on the
//// JavaScript target.
////
//// It renders **raw HTML** with headless Chrome and pixel-diffs the result
//// against a committed baseline with [odiff](https://github.com/dmtrKovalenko/odiff).
//// Because it works on HTML strings, it is view-layer agnostic: use it with
//// [Lustre](https://hexdocs.pm/lustre/) (pass `lustre/element.to_string(view)`),
//// an htmx server that emits HTML fragments, or any hand-written template.
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
//// ## The regression loop
////
//// `matches_baseline` is designed so a real visual regression keeps the build
//// **red** until a human explicitly accepts the change. On a mismatch it writes
//// a *proposed* screenshot next to the baseline (`<baseline>.<platform>.new.png`)
//// and a visual diff (`<baseline>.<platform>.diff.png`) — but it never
//// overwrites the baseline itself. The proposal is there to review (and to
//// upload as a CI artifact); promote it with `accept` once you've confirmed the
//// change is intentional.

import child_process
import child_process/stdio
import envoy
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import screenshot/dom
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
  /// captured render, kept so it can be promoted with `accept`. Fail.
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

/// Override the viewport size on an `Options`.
pub fn with_size(options: Options, size: ScreenSize) -> Options {
  Options(..options, size:)
}

/// Override the odiff per-pixel colour threshold (0.0–1.0) on an `Options`.
/// Larger values tolerate bigger per-pixel colour differences.
pub fn with_threshold(options: Options, threshold: Float) -> Options {
  Options(..options, threshold:)
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
  use render_abs <- result.try(write_scratch(html, base, path))
  run_chrome(render_abs, path, size)
}

/// Inject `content` into the HTML `template` file at the first element matching
/// `selector`, then screenshot the combined page into `path`.
///
/// The scratch render is written next to the template, so the template's
/// relative `<link rel="stylesheet">` / `<img>` paths resolve. Requires
/// `linkedom`.
pub fn capture_in_template(
  content content: String,
  into template: String,
  at selector: String,
  to path: String,
  size size: ScreenSize,
) -> Result(Nil, Error) {
  use combined <- result.try(render(content, template, selector))
  use template_abs <- result.try(absolute(template))
  let render_abs =
    directory_of(template_abs)
    <> "/.screenshot_render."
    <> slug(path)
    <> ".html"
  use _ <- result.try(
    simplifile.write(to: render_abs, contents: combined)
    |> result.replace_error(WriteFailed(render_abs)),
  )
  run_chrome(render_abs, path, size)
}

/// Read the HTML `template` file and inject `content` at the first element
/// matching `selector` (the same shape as `lustre.start`'s mount point),
/// returning the combined document. Requires `linkedom`.
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

  case
    child_process.from_file(odiff)
    |> child_process.args(args)
    |> child_process.run(stdio.capture(capture_stderr: True))
  {
    Ok(child_process.Output(status_code: 0, ..)) -> Ok(True)
    Ok(child_process.Output(status_code: 22, ..)) -> Ok(False)
    Ok(child_process.Output(status_code:, output:)) ->
      Error(DiffFailed(status: status_code, output:))
    Error(_) ->
      Error(DiffFailed(status: -1, output: "failed to start odiff at " <> odiff))
  }
}

// MARK: Baseline regression helper

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
/// build stays red until you `accept` the proposal. On a match it returns
/// `Match` and cleans up any stale proposal/diff so a green run leaves no
/// noise.
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
  let plat = dom.platform()
  let golden = baseline <> "." <> plat <> ".png"
  let proposed = baseline <> "." <> plat <> ".new.png"
  let diff_path = baseline <> "." <> plat <> ".diff.png"

  let _ = simplifile.create_directory_all(directory_of(proposed))
  use _ <- result.try(capture_in_template(
    content:,
    into: options.template,
    at: options.selector,
    to: proposed,
    size: options.size,
  ))

  case simplifile.is_file(golden) {
    Ok(True) -> {
      use matched <- result.try(diff(
        a: golden,
        b: proposed,
        to: diff_path,
        threshold: options.threshold,
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

/// Promote a proposed screenshot to the committed baseline for the current
/// platform: copies `<baseline>.<platform>.new.png` over
/// `<baseline>.<platform>.png` and removes the proposal. Call this once you've
/// confirmed a `Mismatch`/`Missing` is an intentional UI change.
pub fn accept(baseline baseline: String) -> Result(Nil, Error) {
  let plat = dom.platform()
  let proposed = baseline <> "." <> plat <> ".new.png"
  let golden = baseline <> "." <> plat <> ".png"
  use _ <- result.try(
    simplifile.copy_file(at: proposed, to: golden)
    |> result.replace_error(WriteFailed(golden)),
  )
  let _ = simplifile.delete(proposed)
  Ok(Nil)
}

/// Promote every proposed screenshot found under `dir` (recursively): each
/// file ending in `.new.png` is copied over its baseline (the `.new` segment
/// dropped) and removed. Returns how many were promoted. Useful for an "accept
/// baselines" CI job.
pub fn accept_all(dir dir: String) -> Result(Int, Error) {
  use files <- result.try(
    simplifile.get_files(in: dir)
    |> result.replace_error(WriteFailed(dir)),
  )
  files
  |> list.filter(string.ends_with(_, ".new.png"))
  |> list.try_fold(0, fn(count, proposed) {
    let golden = string.replace(proposed, ".new.png", ".png")
    use _ <- result.try(
      simplifile.copy_file(at: proposed, to: golden)
      |> result.replace_error(WriteFailed(golden)),
    )
    let _ = simplifile.delete(proposed)
    Ok(count + 1)
  })
}

// MARK: Internals

fn run_chrome(
  render_abs: String,
  path: String,
  size: ScreenSize,
) -> Result(Nil, Error) {
  use chrome <- result.try(env("CHROME_BIN"))

  let args = [
    "--headless=new",
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

  case
    child_process.from_file(chrome)
    |> child_process.args(args)
    |> child_process.run(stdio.capture(capture_stderr: True))
  {
    Ok(child_process.Output(status_code: 0, ..)) -> Ok(Nil)
    Ok(child_process.Output(status_code:, output:)) ->
      Error(BrowserFailed(status: status_code, output:))
    Error(_) ->
      Error(BrowserFailed(
        status: -1,
        output: "failed to start chrome at " <> chrome,
      ))
  }
}

fn write_scratch(
  html: String,
  base: String,
  path: String,
) -> Result(String, Error) {
  use base_abs <- result.try(absolute(base))
  let render_abs = base_abs <> "/.screenshot_render." <> slug(path) <> ".html"
  use _ <- result.try(
    simplifile.write(to: render_abs, contents: html)
    |> result.replace_error(WriteFailed(render_abs)),
  )
  Ok(render_abs)
}

fn env(name: String) -> Result(String, Error) {
  envoy.get(name) |> result.replace_error(MissingBinary(name))
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
