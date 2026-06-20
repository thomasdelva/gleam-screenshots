// The host platform as Node's `process.platform` reports it ("linux", "darwin",
// "win32", ...). Mirrored by screenshot_ffi:platform/0 on the BEAM.
export function platform() {
  return process.platform;
}
