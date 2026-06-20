import { spawnSync } from "node:child_process";

// Run an executable to completion. Returns a Gleam #(Int, String) — represented
// as a 2-element array on the JS target — of (exit status, stderr+stdout). A
// status of -1 signals the process could not be started.
export function run(executable, args) {
  const result = spawnSync(executable, args.toArray(), { encoding: "utf8" });
  if (result.error) {
    return [-1, `failed to start ${executable}: ${result.error.message}`];
  }
  const output = (result.stdout ?? "") + (result.stderr ?? "");
  return [result.status ?? -1, output];
}

// The host platform, as Node's `process.platform` reports it ("linux",
// "darwin", "win32", ...). Mirrored by screenshot_ffi:platform/0 on the BEAM.
export function platform() {
  return process.platform;
}
