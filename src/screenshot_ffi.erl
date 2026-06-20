%% Erlang FFI for `screenshot/exec` and `screenshot/dom` platform detection.
%% Mirrors the JavaScript implementations (exec.ffi.mjs / dom.ffi.mjs) so the
%% library runs on the BEAM as well as on Node.
-module(screenshot_ffi).
-export([run/2, platform/0]).

%% Run an executable to completion, returning a {Status, Output} tuple (a Gleam
%% #(Int, String)) of (exit status, captured stderr+stdout). Status is -1 if the
%% process could not be started. Uses a port with spawn_executable, so the
%% program is run directly (no shell), matching spawnSync on the JS side.
run(Executable, Args) ->
    Exe = unicode:characters_to_list(Executable),
    ArgList = [unicode:characters_to_list(A) || A <- Args],
    try
        open_port(
            {spawn_executable, Exe},
            [exit_status, stderr_to_stdout, binary, hide, {args, ArgList}]
        )
    of
        Port -> collect(Port, [])
    catch
        _:Reason ->
            Msg = io_lib:format("failed to start ~ts: ~p", [Exe, Reason]),
            {-1, unicode:characters_to_binary(Msg)}
    end.

collect(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    end.

%% Host platform as Node's `process.platform` reports it: "linux", "darwin",
%% "win32". Renders are by the same Chrome on both targets, so a baseline is
%% keyed by OS, not by which runtime drove it.
platform() ->
    case os:type() of
        {unix, darwin} -> <<"darwin">>;
        {win32, _} -> <<"win32">>;
        {unix, _} -> <<"linux">>
    end.
