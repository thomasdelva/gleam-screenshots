//// Small FFI surface used by `screenshot`: HTML template injection (via the
//// `linkedom` npm package) and host platform detection. Kept separate so the
//// public `screenshot` module has a single, documented JS dependency.

@target(javascript)
/// Parse `template` as HTML, find the first element matching the CSS
/// `selector`, set its inner HTML to `content`, and return the serialised
/// document. Mirrors how a browser-side runtime resolves a mount point
/// (`document.querySelector(selector)`).
///
/// Returns `Error(message)` if no element matches the selector. Requires the
/// `linkedom` npm package to be installed.
///
/// Template injection is JavaScript-only (it leans on `linkedom`); on the BEAM
/// use the template-free `screenshot.capture` / `document_matches_baseline`.
@external(javascript, "./dom.ffi.mjs", "mount_into_template")
pub fn mount_into_template(
  template template: String,
  selector selector: String,
  content content: String,
) -> Result(String, String)

/// The host platform, as Node's `process.platform` reports it: `"linux"`,
/// `"darwin"`, `"win32"`, etc. Used to keep a separate screenshot baseline per
/// platform, because pixel rendering differs across rasterisation stacks
/// (FreeType vs CoreText vs DirectWrite). Dual-target — renders are by the same
/// Chrome regardless of which runtime drove the capture.
@external(erlang, "screenshot_ffi", "platform")
@external(javascript, "./dom.ffi.mjs", "platform")
pub fn platform() -> String
