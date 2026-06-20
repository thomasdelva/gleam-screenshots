//// OS-facing FFI: run an external executable (capturing its status and output)
//// and detect the host platform.
////
//// Dual-target so the library can shell out to Chrome and odiff on either
//// runtime: Node's `child_process.spawnSync` on JavaScript, an Erlang port on
//// the BEAM. This is the only place that talks to the OS, which is what lets the
//// rest of `screenshot` stay target-agnostic.

/// The result of running an executable: its exit `status` (`-1` if it could not
/// be started at all) and its captured stderr+stdout.
pub type Run {
  Run(status: Int, output: String)
}

/// Run `executable` with `args` to completion, returning its exit status and
/// captured output. Runs the program directly (no shell), so `executable` must
/// be a path to a real binary.
pub fn run(executable executable: String, args args: List(String)) -> Run {
  let #(status, output) = run_ffi(executable, args)
  Run(status:, output:)
}

@external(erlang, "screenshot_ffi", "run")
@external(javascript, "./exec.ffi.mjs", "run")
fn run_ffi(executable: String, args: List(String)) -> #(Int, String)

/// The host platform, as Node's `process.platform` reports it: `"linux"`,
/// `"darwin"`, `"win32"`, etc. Used to keep a separate screenshot baseline per
/// platform, because pixel rendering differs across rasterisation stacks
/// (FreeType vs CoreText vs DirectWrite). The render is by the same Chrome
/// regardless of which runtime drove the capture.
@external(erlang, "screenshot_ffi", "platform")
@external(javascript, "./exec.ffi.mjs", "platform")
pub fn platform() -> String
