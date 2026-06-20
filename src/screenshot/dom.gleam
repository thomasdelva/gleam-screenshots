//// JavaScript-only FFI for `screenshot`: HTML template injection via the
//// `linkedom` npm package. Kept separate so the public `screenshot` module has
//// a single, documented JS dependency. (Platform detection — needed on both
//// targets — lives in `screenshot/exec`.)

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
