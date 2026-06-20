%% Erlang FFI for `screenshot`'s host-platform detection. Mirrors
%% screenshot.ffi.mjs so the library detects the host OS on the BEAM as well as
%% on Node. (Process spawning is handled by the `shellout` dependency, not here.)
-module(screenshot_ffi).
-export([platform/0]).

%% Host platform as Node's `process.platform` reports it: "linux", "darwin",
%% "win32". Renders are by the same Chrome on both targets, so a baseline is
%% keyed by OS, not by which runtime drove it.
platform() ->
    case os:type() of
        {unix, darwin} -> <<"darwin">>;
        {win32, _} -> <<"win32">>;
        {unix, _} -> <<"linux">>
    end.
