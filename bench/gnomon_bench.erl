%% Benchmark harness comparing gnomon's read path with two ETS clocks: the
%% real cowboy_clock, whose binary is off-heap, and gnomon_bench_ets, which
%% holds an on-heap binary. The header reports each clock's storage as
%% observed at startup, so the labels are checked rather than assumed.
%%
%% erlperf counts iterations with a call_count trace on the generated
%% runner, a single counter that every worker increments, which costs more
%% than a 10 ns call. So each runner iteration is a batch of ?BATCH calls
%% in a tight local loop, and the counter's cost is spread over the batch;
%% the empty-loop row shows what remains. Runners are source strings, as
%% erlperf recommends.
%%
%% Three measurements per case:
%%
%% * A scaling curve from erlperf's concurrency estimation mode, stepping
%%   from one worker to one per scheduler without stopping early. The
%%   report's result is the last step; the curve is its history.
%% * A continuous run with many workers sharing the schedulers, the shape
%%   of a BEAM web server with one process per connection.
%% * Timed mode at one worker, the lowest-overhead measurement erlperf has.
-module(gnomon_bench).

-export([main/0, main/1]).
-export([loop_ets/1, loop_cowboy/1, loop_date/1, loop_empty/1]).

%% {Label, loop function taking a call count}
-define(READ_CASES, [
    {"ETS, off-heap binary (cowboy_clock)", loop_cowboy},
    {"ETS, on-heap binary", loop_ets},
    {"gnomon:date/0", loop_date},
    {"Empty loop, the floor", loop_empty}
]).

%% Calls per erlperf iteration.
-define(BATCH, 1000).

%% Worker count for the many-worker run. Quick mode uses fewer to keep the
%% CI smoke run short.
-define(MANY_FULL, 100000).
-define(MANY_QUICK, 1000).

-define(WIDTH, 120).

-spec main() -> ok.
main() ->
    main([]).

-spec main([string()]) -> ok.
main(Args) ->
    Quick = lists:member("quick", Args),
    Opts =
        case Quick of
            true -> #{samples => 2, warmup => 0, many => ?MANY_QUICK};
            false -> #{samples => 5, warmup => 1, many => ?MANY_FULL}
        end,
    Cowboy = setup(),
    Env = environment(Quick, Cowboy),
    print_environment(Env),
    _ = read_benchmarks(Opts, Cowboy),
    ok.

%%--------------------------------------------------------------------
%% Setup
%%--------------------------------------------------------------------

setup() ->
    {ok, _} = application:ensure_all_started(erlperf),
    {ok, _} = application:ensure_all_started(gnomon),
    {ok, _} = gnomon_bench_ets:start_link(),
    case application:ensure_all_started(cowboy) of
        {ok, _} ->
            %% cowboy_sup starts cowboy_clock; wait for its table.
            true = wait_until(fun() -> ets:whereis(cowboy_clock) =/= undefined end, 10_000),
            true;
        {error, Reason} ->
            io:format("Cowboy not started (~p); skipping the cowboy_clock case.~n~n", [Reason]),
            false
    end.

%%--------------------------------------------------------------------
%% Read path
%%--------------------------------------------------------------------

read_benchmarks(Opts, Cowboy) ->
    Schedulers = erlang:system_info(schedulers_online),
    Cases = [C || C = {_, Loop} <- ?READ_CASES, Cowboy orelse Loop =/= loop_cowboy],
    #{samples := Samples, warmup := Warmup, many := Many} = Opts,
    ErlperfOpts = #{samples => Samples, warmup => Warmup},
    Estimation = #{min => 1, max => Schedulers, step => 1, threshold => Schedulers},

    heading("Read path, erlperf, ~B calls per iteration", [?BATCH]),
    io:format(
        "Scaling: concurrency estimation from 1 to ~B workers in steps of 1, never stopping "
        "early; ~B sample(s) of 1 s after ~B warmup sample(s) per step. Many workers: ~s "
        "workers, same sampling. Timed: one worker, ~B measured run(s) of a fixed iteration "
        "count. In erlperf's tables Code is the runner and Iteration is per ~B calls.~n~n",
        [Schedulers, Samples, Warmup, commas(Many), Samples, ?BATCH]
    ),
    Rows = [
        begin
            progress("scaling: ~s", [Short]),
            Runner = runner(Loop),
            #{history := History} = erlperf:run(Runner, ErlperfOpts#{report => full}, Estimation),
            Curve = lists:sort([
                {C, round(Avg * ?BATCH), C * 1.0e9 / max(1.0, Avg * ?BATCH)}
             || {C, #{average := Avg}} <- History
            ]),
            progress("~s workers: ~s", [commas(Many), Short]),
            {ReportM, QM} = continuous(Runner, ?BATCH, ErlperfOpts#{concurrency => Many}),
            NM = Schedulers * 1.0e9 / max(1, QM),
            progress("timed: ~s", [Short]),
            {ReportT, T} = timed(Runner, ErlperfOpts),
            #{
                short => Short,
                curve => Curve,
                report_m => ReportM,
                qm => QM,
                nm => NM,
                report_t => ReportT,
                t => T
            }
        end
     || {Short, Loop} <- Cases
    ],

    io:format("Scaling, calls per second over all workers:~n"),
    curve_table(Rows, fun({_, Q, _}) -> commas(Q) end),
    io:format("Scaling, ns per call per worker:~n"),
    curve_table(Rows, fun({_, _, N}) -> ns(N) end),

    io:format("~s workers, erlperf report:~n", [commas(Many)]),
    io:put_chars(
        erlperf_cli:format([R || #{report_m := R} <- Rows], #{
            format => extended, viewport_width => ?WIDTH
        })
    ),
    io:format("~n~s workers, per call (ns per call is scheduler time, ~B schedulers):~n", [
        commas(Many), Schedulers
    ]),
    text_table(
        ["Case", "calls/s", "ns/call per scheduler"],
        [[Short, commas(QM), ns(NM)] || #{short := Short, qm := QM, nm := NM} <- Rows]
    ),

    io:format("Timed mode, 1 worker, erlperf report:~n"),
    io:put_chars(
        erlperf_cli:format([R || #{report_t := R} <- Rows], #{
            format => extended, viewport_width => ?WIDTH
        })
    ),
    io:format("~nTimed mode, 1 worker, per call:~n"),
    text_table(["Case", "ns/call"], [[Short, ns(T)] || #{short := Short, t := T} <- Rows]),
    #{schedulers => Schedulers, many => Many, rows => Rows}.

%% Workers down the side, cases across, one cell per (workers, case).
curve_table(Rows, Cell) ->
    Header = ["Workers" | [Short || #{short := Short} <- Rows]],
    Counts = [C || {C, _, _} <- maps:get(curve, hd(Rows))],
    Body = [
        [integer_to_list(C) | [Cell(lists:keyfind(C, 1, Curve)) || #{curve := Curve} <- Rows]]
     || C <- Counts
    ],
    text_table(Header, Body).

%% An erlperf runner that calls the loop function with the batch size.
runner(Loop) ->
    lists:flatten(io_lib:format("gnomon_bench:~s(~B).", [Loop, ?BATCH])).

%% Calls per second over all workers, from erlperf's average iterations
%% per 1 s sample and the number of calls per iteration. The full report's
%% average is a float; erlperf's own iteration_time is an integer, which
%% would truncate the fast rows.
continuous(Runner, CallsPerIteration, Opts) ->
    #{result := #{average := Avg}} = Report = erlperf:run(Runner, Opts#{report => full}),
    {Report, round(Avg * CallsPerIteration)}.

%% Timed mode: erlperf loops the runner Count times per sample. The full
%% report carries the total measured time in microseconds. Size Count so a
%% sample takes about a second. erlperf:time/2 returns milliseconds.
timed(Runner, #{samples := Samples, warmup := Warmup}) ->
    %% erlperf:time/2 reports whole milliseconds, so the probe must run long
    %% enough to register even for the empty loop.
    Probe = 10000,
    ProbeUs = max(1000, erlperf:time(Runner, Probe) * 1000),
    Count = max(Probe, min(2000000, Probe * 1000000 div ProbeUs)),
    #{result := #{time := TotalUs}} =
        Report = erlperf:run(Runner, #{
            sample_duration => {timed, Count},
            samples => Samples,
            warmup => Warmup,
            report => full
        }),
    {Report, TotalUs * 1000 / (Samples * Count * ?BATCH)}.

loop_ets(0) ->
    ok;
loop_ets(N) ->
    _ = gnomon_bench_ets:rfc1123(),
    loop_ets(N - 1).

loop_cowboy(0) ->
    ok;
loop_cowboy(N) ->
    _ = cowboy_clock:rfc1123(),
    loop_cowboy(N - 1).

loop_date(0) ->
    ok;
loop_date(N) ->
    _ = gnomon:date(),
    loop_date(N - 1).

loop_empty(0) -> ok;
loop_empty(N) -> loop_empty(N - 1).

%%--------------------------------------------------------------------
%% Environment
%%--------------------------------------------------------------------

environment(Quick, Cowboy) ->
    [
        {"Mode", atom_to_list(mode(Quick))},
        {"OTP", fmt("~s, ERTS ~s", [erlang:system_info(otp_release), erlang:system_info(version)])},
        {"Emulator", fmt("~s, JIT ~s", [emu_type(), jit()])},
        {"Architecture",
            fmt("~s, ~B-bit words", [
                erlang:system_info(system_architecture), 8 * erlang:system_info(wordsize)
            ])},
        {"Schedulers online", integer_to_list(erlang:system_info(schedulers_online))},
        {"CPU", cpu()},
        {"Versions", fmt("erlperf ~s, cowboy ~s", [vsn(erlperf), vsn(cowboy)])},
        {"ETS binaries", ets_binaries(Cowboy)}
    ].

%% Where the binary each ETS clock serves lives, observed rather than
%% assumed: a fresh process does one lookup, then lists the off-heap
%% binaries it references. An on-heap binary leaves that list empty.
ets_binaries(Cowboy) ->
    Real =
        case Cowboy of
            true -> storage(fun cowboy_clock:rfc1123/0);
            false -> "not started"
        end,
    fmt("cowboy_clock ~s, gnomon_bench_ets ~s", [Real, storage(fun gnomon_bench_ets:rfc1123/0)]).

storage(Lookup) ->
    Parent = self(),
    Ref = make_ref(),
    _ = spawn(fun() ->
        _ = Lookup(),
        {binary, Bins} = process_info(self(), binary),
        Parent ! {Ref, Bins}
    end),
    receive
        {Ref, []} -> "on-heap";
        {Ref, [_ | _]} -> "off-heap"
    after 5000 -> "unknown"
    end.

mode(true) -> quick;
mode(false) -> full.

print_environment(Env) ->
    heading("gnomon benchmark", []),
    [io:format("~-20s ~s~n", [K ++ ":", V]) || {K, V} <- Env],
    ok.

emu_type() ->
    try erlang:system_info(emu_type) of
        T -> atom_to_list(T)
    catch
        error:badarg -> "unknown"
    end.

jit() ->
    try erlang:system_info(emu_flavor) of
        jit -> "enabled";
        Other -> "disabled (" ++ atom_to_list(Other) ++ ")"
    catch
        error:badarg -> "unknown"
    end.

cpu() ->
    Cmd =
        case os:type() of
            {unix, darwin} -> "sysctl -n machdep.cpu.brand_string";
            {unix, _} -> "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2";
            _ -> "echo unknown"
        end,
    string:trim(os:cmd(Cmd)).

vsn(App) ->
    case application:get_key(App, vsn) of
        {ok, V} -> V;
        undefined -> "not loaded"
    end.

%%--------------------------------------------------------------------
%% Text output
%%--------------------------------------------------------------------

heading(Format, Args) ->
    Title = fmt(Format, Args),
    io:format("~n~s~n~s~n", [Title, lists:duplicate(length(Title), $=)]).

%% Progress goes to standard error so a redirected stdout stays clean.
progress(Format, Args) ->
    io:format(standard_error, "  ... ~s~n", [fmt(Format, Args)]).

%% An aligned table: the first column left-aligned, the rest right-aligned.
text_table(Header, Rows) ->
    All = [[lists:flatten(C) || C <- Row] || Row <- [Header | Rows]],
    Widths = [
        lists:max([length(lists:nth(I, Row)) || Row <- All])
     || I <- lists:seq(1, length(Header))
    ],
    Line = fun([First | Rest], [W1 | Ws]) ->
        io:format("~s~s~n", [
            string:pad(First, W1, trailing),
            [["  ", string:pad(C, W, leading)] || {C, W} <- lists:zip(Rest, Ws)]
        ])
    end,
    Line(hd(All), Widths),
    io:format("~s~n", [lists:duplicate(lists:sum(Widths) + 2 * (length(Widths) - 1), $-)]),
    [Line(Row, Widths) || Row <- tl(All)],
    io:format("~n").

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

fmt(Format, Args) ->
    lists:flatten(io_lib:format(Format, Args)).

commas(N) when is_integer(N) ->
    S = integer_to_list(N),
    lists:reverse(commas_rev(lists:reverse(S)));
commas(F) when is_float(F) ->
    commas(round(F)).

commas_rev([A, B, C | Rest = [_ | _]]) -> [A, B, C, $, | commas_rev(Rest)];
commas_rev(L) -> L.

%% Nanoseconds per call with one decimal.
ns(F) when is_number(F) ->
    io_lib:format("~.1f", [F * 1.0]).

wait_until(Fun, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_loop(Fun, Deadline).

wait_loop(Fun, Deadline) ->
    case Fun() of
        true ->
            true;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    false;
                false ->
                    timer:sleep(10),
                    wait_loop(Fun, Deadline)
            end
    end.
