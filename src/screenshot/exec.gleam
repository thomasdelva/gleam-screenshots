//// Run an external executable, capturing its exit status and combined output.
////
//// A thin wrapper over the `shellout` package, which spawns the program
//// directly (no shell) on both Node and the BEAM and redirects stderr into
//// stdout. This is the only place the library touches the OS process layer,
//// which is what lets the rest of `screenshot` stay target-agnostic.

import shellout

/// The result of running an executable: its exit `status` and its captured
/// stderr+stdout.
pub type Run {
  Run(status: Int, output: String)
}

/// Run `executable` with `args` to completion, returning its exit status and
/// combined output. The program is run directly (no shell), so `executable`
/// must be a path to a real binary.
pub fn run(executable executable: String, args args: List(String)) -> Run {
  case shellout.command(run: executable, with: args, in: ".", opt: []) {
    Ok(output) -> Run(status: 0, output:)
    Error(#(status, output)) -> Run(status:, output:)
  }
}
