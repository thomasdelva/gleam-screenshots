//// Project-agnostic screenshot regression testing for Gleam web UIs, on the
//// JavaScript target or the BEAM.
////
//// It renders **raw HTML** with headless Chrome and pixel-diffs the result
//// against a committed baseline with [odiff](https://github.com/dmtrKovalenko/odiff).
//// Because it works on complete HTML document strings, it is view-layer
//// agnostic: use it with [Lustre](https://hexdocs.pm/lustre/) (pass
//// `lustre/element.to_string(view)`), an htmx server that emits HTML, or any
//// hand-written template. The same code runs on Node and on Erlang/OTP —
//// Chrome and odiff are driven through the dual-target `shellout` package.
////
//// ## Binaries
////
//// External tools are located through environment variables so the same code
//// runs locally and in CI:
////
//// - `CHROME_BIN` — a `chrome-headless-shell` executable (see below).
//// - `ODIFF_BIN`  — the odiff executable (`npm i -D odiff-bin` installs one at
////   `node_modules/.bin/odiff`).
////
//// `CHROME_BIN` should be a [`chrome-headless-shell`](https://developer.chrome.com/blog/chrome-headless-shell)
//// binary — the maintained standalone successor to old headless. It sizes the
//// rendered viewport to the requested `ScreenSize` exactly, which is why the
//// library wants it: full Chrome's `--headless=new --screenshot` reserves a
//// fixed shorter viewport, leaving a letterbox band. Get the pinned build with
//// `npx @puppeteer/browsers install chrome-headless-shell@<version>`.
////
//// odiff's per-pixel colour threshold defaults to `0.1`; override it for a
//// whole run with `SCREENSHOT_THRESHOLD` (e.g. `0.2`) to tame cross-environment
//// rendering jitter without touching tests or baselines.
////
//// ## The regression loop
////
//// `document_matches_baseline` is designed so a real visual regression keeps
//// the build **red** until a human explicitly accepts the change. On a mismatch
//// it writes a *proposed* screenshot next to the baseline
//// (`<baseline>.<platform>.new.png`) and a visual diff
//// (`<baseline>.<platform>.diff.png`) — but it never overwrites the baseline.
////
//// To accept intentional changes, re-run the suite with `SCREENSHOT_ACCEPT=true`
//// (`SCREENSHOT_ACCEPT=true gleam test`): every baseline that has drifted past
//// the threshold (or is missing) is refreshed from the current render and the
//// suite passes — unchanged baselines are left alone. That single command is
//// what the one-click CI accept job runs.

import envoy
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import shellout
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

/// Opt-in capture options for **live JavaScript UIs** — anything that draws to
/// a `<canvas>` via WebGL or only appears after async work (a map, a chart, a 3D
/// scene). Both knobs are off by default (`options()`), so a plain static
/// snapshot needs nothing extra. See [`with_webgl`](#with_webgl) and
/// [`with_settle`](#with_settle).
pub type Options {
  Options(webgl: Bool, settle: Int)
}

/// Default capture options: a single static snapshot — no WebGL, no settle wait.
/// Build up from here with `with_webgl` / `with_settle`.
pub fn options() -> Options {
  Options(webgl: False, settle: 0)
}

/// Render through a software-rasterised WebGL backend (SwiftShader) and allow the
/// page's `file://` ES modules to load. Turn this on to screenshot anything that
/// draws to a `<canvas>` via WebGL. Off by default.
///
/// SwiftShader is deterministic for a given Chrome build, which is what makes a
/// committed WebGL baseline reproducible — but pixels still differ across Chrome
/// versions, so pin the browser version in CI. Almost always paired with
/// [`with_settle`](#with_settle): a WebGL UI needs a frame or two (and usually
/// some async setup) before it has anything to show.
pub fn with_webgl(options: Options) -> Options {
  Options(..options, webgl: True)
}

/// Wait for the page to settle before screenshotting, instead of capturing at
/// first paint. `ms` is a Chrome *virtual-time* budget, **not** a wall-clock
/// wait: the clock is fast-forwarded — timers, `requestAnimationFrame`, and
/// pending fetches fire as fast as the CPU can run them — and the frame is
/// captured once that work drains or the budget is reached, whichever comes
/// first. So the budget is a *ceiling*, not a cost: a page that goes idle after
/// 1s of page-time is captured then even with a `12_000` budget, and the real
/// time spent is just the work itself (typically well under a wall-clock
/// second). Set it generously. `0` (the default) captures immediately — the
/// right choice for static HTML.
pub fn with_settle(options: Options, ms ms: Int) -> Options {
  Options(..options, settle: ms)
}

// MARK: Capture

/// Screenshot a complete HTML document string into `path` (a PNG).
///
/// The document is written to a scratch file inside `base` so any **relative**
/// URLs it references (stylesheets, images) resolve against that directory
/// under the `file://` URL Chrome loads. The scratch file name is derived from
/// `path`, so independent captures running concurrently never collide.
pub fn capture(
  html html: String,
  to path: String,
  size size: ScreenSize,
  base base: String,
  options options: Options,
) -> Result(Nil, Error) {
  use base_abs <- result.try(absolute(base))
  let render_abs = base_abs <> "/.screenshot_render." <> slug(path) <> ".html"
  use _ <- result.try(
    simplifile.write(to: render_abs, contents: html)
    |> result.replace_error(WriteFailed(render_abs)),
  )
  let outcome = run_chrome(render_abs, path, size, options)
  // The scratch render is only needed while Chrome loads it; remove it so it
  // doesn't linger in (and get committed from) the caller's working tree.
  let _ = simplifile.delete(render_abs)
  outcome
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

  // odiff exits 0 when the images match and 22 when they differ; any other
  // status (e.g. odiff couldn't be started) is a genuine failure. `shellout`
  // returns `Ok` only on exit 0, so a nonzero status arrives in the `Error` arm.
  case shellout.command(run: odiff, with: args, in: ".", opt: []) {
    Ok(_) -> Ok(True)
    Error(#(22, _)) -> Ok(False)
    Error(#(status, output)) -> Error(DiffFailed(status:, output:))
  }
}

// MARK: Baseline regression helper

/// Screenshot a **complete HTML document** and compare it against the committed
/// baseline for the current platform.
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
/// screenshot.document_matches_baseline(document:, baseline:, size:, threshold:)
/// |> should.equal(Ok(screenshot.Match))
/// ```
pub fn document_matches_baseline(
  document document: String,
  baseline baseline: String,
  size size: ScreenSize,
  threshold threshold: Float,
  options options: Options,
) -> Result(Outcome, Error) {
  check_baseline(baseline, threshold, fn(proposed) {
    capture(
      html: document,
      to: proposed,
      size:,
      base: directory_of(proposed),
      options:,
    )
  })
}

/// The shared accept / compare / missing loop behind `document_matches_baseline`.
/// `capture_to` renders the subject into the given proposal path; everything
/// after that — accept mode, the odiff compare, keeping proposals/diffs on
/// failure, cleaning up on a match — is the regression machinery.
fn check_baseline(
  baseline: String,
  threshold: Float,
  capture_to: fn(String) -> Result(Nil, Error),
) -> Result(Outcome, Error) {
  let plat = platform()
  let golden = baseline <> "." <> plat <> ".png"
  let proposed = baseline <> "." <> plat <> ".new.png"
  let diff_path = baseline <> "." <> plat <> ".diff.png"

  let _ = simplifile.create_directory_all(directory_of(proposed))
  use _ <- result.try(capture_to(proposed))

  case simplifile.is_file(golden) {
    Ok(True) -> {
      use matched <- result.try(diff(
        a: golden,
        b: proposed,
        to: diff_path,
        threshold: threshold_for(threshold),
      ))
      case matched, accepting() {
        // Within threshold: the render still matches the baseline (in either
        // mode). Leave the baseline untouched, clean up, pass.
        True, _ -> {
          let _ = simplifile.delete(proposed)
          let _ = simplifile.delete(diff_path)
          Ok(Match)
        }
        // Exceeds the threshold in accept mode: adopt the new render as the
        // baseline and pass. Only changed baselines are rewritten, so an accept
        // run produces a commit only for what actually moved.
        False, True -> {
          use _ <- result.try(adopt(proposed:, golden:))
          let _ = simplifile.delete(diff_path)
          Ok(Match)
        }
        // Exceeds the threshold in compare mode: a regression.
        False, False -> Ok(Mismatch(diff: diff_path, proposed:))
      }
    }
    // No baseline yet: accept mode creates it; otherwise report it missing.
    _ ->
      case accepting() {
        True -> {
          use _ <- result.try(adopt(proposed:, golden:))
          Ok(Match)
        }
        False -> Ok(Missing(proposed:))
      }
  }
}

/// Adopt a proposed render as the committed baseline: move it onto `golden` and
/// drop the proposal.
fn adopt(proposed proposed: String, golden golden: String) -> Result(Nil, Error) {
  use _ <- result.try(
    simplifile.copy_file(at: proposed, to: golden)
    |> result.replace_error(WriteFailed(golden)),
  )
  let _ = simplifile.delete(proposed)
  Ok(Nil)
}

/// Whether the suite is running in accept mode (`SCREENSHOT_ACCEPT=true`), in
/// which a render that has drifted past the threshold (or has no baseline yet)
/// is adopted as the new baseline instead of failing.
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
  options: Options,
) -> Result(Nil, Error) {
  use chrome <- result.try(env("CHROME_BIN"))

  // chrome-headless-shell is always headless and sizes the viewport to
  // `--window-size` exactly, so no `--headless` flag is passed and the capture
  // fills the requested `ScreenSize` with no letterbox band. (Why this binary
  // rather than full Chrome: see the module doc.)
  let args =
    list.flatten([
      [
        "--no-sandbox",
        "--hide-scrollbars",
        // Pin DPI so renders are deterministic across machines.
        "--force-device-scale-factor=1",
        "--screenshot=" <> path,
        "--window-size="
          <> int.to_string(size.width)
          <> ","
          <> int.to_string(size.height),
      ],
      gpu_args(options.webgl),
      settle_args(options.settle),
      ["file://" <> render_abs],
    ])

  case shellout.command(run: chrome, with: args, in: ".", opt: []) {
    Ok(_) -> Ok(Nil)
    Error(#(status, output)) -> Error(BrowserFailed(status:, output:))
  }
}

fn env(name: String) -> Result(String, Error) {
  envoy.get(name) |> result.replace_error(MissingBinary(name))
}

/// GPU flags. The static-HTML path keeps `--disable-gpu` (fast, no GL stack).
/// The WebGL path instead forces ANGLE's SwiftShader software rasteriser — the
/// only way to get a deterministic `<canvas>` render headless on a GPU-less CI
/// box, and required at all since Chrome 137 stopped auto-falling-back to it —
/// and opens `file://` ES-module loading (off by default under the `null`
/// origin), which a bundled web component needs to import its own modules.
fn gpu_args(webgl: Bool) -> List(String) {
  case webgl {
    False -> ["--disable-gpu"]
    True -> [
      "--use-gl=angle",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
      "--allow-file-access-from-files",
    ]
  }
}

/// Settle flags. With a budget, Chrome runs every compositor stage and advances
/// a virtual clock (so timers/rAF/fetches drain) before the screenshot, instead
/// of firing at first paint; the networking flags keep that virtual clock from
/// stalling on Chrome's own background phone-home. `0` adds nothing.
fn settle_args(settle: Int) -> List(String) {
  case settle > 0 {
    False -> []
    True -> [
      "--run-all-compositor-stages-before-draw",
      "--disable-background-networking",
      "--disable-component-update",
      "--no-first-run",
      "--virtual-time-budget=" <> int.to_string(settle),
    ]
  }
}

/// The host platform as Node's `process.platform` reports it ("linux",
/// "darwin", "win32"). Baselines are keyed by OS because pixel rendering
/// differs across rasterisation stacks; the render is by the same Chrome
/// regardless of which runtime drove the capture.
@external(erlang, "screenshot_ffi", "platform")
@external(javascript, "./screenshot.ffi.mjs", "platform")
fn platform() -> String

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
