-module(gnomon_clock_tests).

-include_lib("eunit/include/eunit.hrl").

%% Supervisor callback and probe child used by the start-order test.
-export([init/1, probe_init/1]).

-define(KEY, gnomon_date).

%% Generous bounds so loaded CI runners do not flake.
-define(TICK_DEADLINE_MS, 3000).
-define(TICK_LATENESS_BOUND_MS, 500).

%%--------------------------------------------------------------------
%% Single worker
%%--------------------------------------------------------------------

worker_test_() ->
    {foreach, fun start_worker/0, fun stop_worker/1, [
        fun value_exists_after_start_link/1,
        fun value_changes_across_second_boundary/1,
        fun tick_lands_shortly_after_second_boundary/1,
        fun unexpected_messages_are_ignored/1,
        fun stop_erases_the_key/1,
        fun worker_is_registered/1
    ]}.

start_worker() ->
    gnomon:clear(),
    {ok, Pid} = gnomon_clock:start_link(),
    Pid.

stop_worker(Pid) ->
    try
        gen_server:stop(Pid)
    catch
        exit:_ -> ok
    end,
    gnomon:clear().

value_exists_after_start_link(Pid) ->
    fun() ->
        ?assert(is_process_alive(Pid)),
        P = persistent_term:get(?KEY, undefined),
        ?assert(is_integer(P)),
        ?assert(prop_gnomon:immediate_iff_64_bit(P)),
        assert_served(fun gnomon:date/0)
    end.

value_changes_across_second_boundary(_Pid) ->
    fun() ->
        P1 = persistent_term:get(?KEY),
        P2 = wait_for_change(P1),
        ?assert(P2 > P1),
        assert_served(fun gnomon:date/0)
    end.

%% Observe when the value changes and check that this happens soon after
%% the system clock crossed a second boundary.
tick_lands_shortly_after_second_boundary(_Pid) ->
    fun() ->
        P1 = persistent_term:get(?KEY),
        _ = wait_for_change(P1),
        Lateness = erlang:system_time(millisecond) rem 1000,
        ?assert(Lateness < ?TICK_LATENESS_BOUND_MS),
        %% And the written value is for the second that just began.
        T = erlang:system_time(second),
        P = persistent_term:get(?KEY),
        ?assert(lists:member(P, [gnomon:pack(T - 1), gnomon:pack(T)]))
    end.

unexpected_messages_are_ignored(Pid) ->
    fun() ->
        Pid ! garbage,
        Pid ! {'EXIT', self(), normal},
        ok = gen_server:cast(Pid, garbage),
        ?assertEqual(ignored, gen_server:call(Pid, garbage)),
        ?assert(is_process_alive(Pid)),
        P1 = persistent_term:get(?KEY),
        ?assert(wait_for_change(P1) > P1),
        %% A stray tick, bare or shaped like a timer expiry, must not
        %% arm a second timer. Check right after a real tick so the
        %% next one is about a second away.
        P2 = persistent_term:get(?KEY),
        _ = wait_for_change(P2),
        #{timer := Ref} = sys:get_state(Pid),
        Pid ! tick,
        Pid ! {timeout, make_ref(), tick},
        ?assertEqual(ignored, gen_server:call(Pid, sync)),
        ?assertMatch(#{timer := Ref}, sys:get_state(Pid)),
        ?assert(is_process_alive(Pid))
    end.

stop_erases_the_key(Pid) ->
    fun() ->
        ?assert(is_integer(persistent_term:get(?KEY, undefined))),
        ok = gen_server:stop(Pid),
        ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
        assert_now(fun gnomon:date/0)
    end.

worker_is_registered(Pid) ->
    fun() -> ?assertEqual(Pid, whereis(gnomon_clock)) end.

%% A second start is refused and leaves the running worker alone.
second_start_is_refused_test() ->
    gnomon:clear(),
    {ok, A} = gnomon_clock:start_link(),
    ?assertEqual({error, {already_started, A}}, gnomon_clock:start_link()),
    ?assert(is_process_alive(A)),
    ?assert(is_integer(persistent_term:get(?KEY, undefined))),
    assert_served(fun gnomon:date/0),
    ok = gen_server:stop(A),
    ?assertEqual(undefined, whereis(gnomon_clock)),
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
    %% And a fresh start works once the name is free.
    {ok, B} = gnomon_clock:start_link(),
    ?assertEqual(B, whereis(gnomon_clock)),
    ok = gen_server:stop(B).

%%--------------------------------------------------------------------
%% The application
%%--------------------------------------------------------------------

application_test_() ->
    {foreach, fun start_app/0, fun stop_app/1, application_tests(erlang:system_info(wordsize))}.

%% With 64-bit words the application supervises one clock.
application_tests(8) ->
    [
        fun app_serves_the_date/0,
        fun app_supervises_one_registered_clock/0,
        fun app_stop_erases_the_key/0,
        fun killed_clock_is_restarted_with_the_value/0,
        fun terminate_child_erases_and_restart_child_restores/0,
        fun clock_dying_past_intensity_stops_the_app_and_erases/0
    ];
%% With 32-bit words it runs no clock and every read takes the fallback.
application_tests(4) ->
    [
        fun app_runs_no_clock/0,
        fun app_stops_without_a_clock/0
    ].

start_app() ->
    gnomon:clear(),
    %% The kills below are deliberate; keep their reports out of the output.
    ok = logger:set_module_level([supervisor, application_controller], none),
    {ok, _} = application:ensure_all_started(gnomon),
    ok.

stop_app(_) ->
    _ = application:stop(gnomon),
    ok = logger:unset_module_level([supervisor, application_controller]),
    gnomon:clear().

%% Both word sizes' child lists, whatever emulator runs the suite.
clock_runs_only_on_64_bit_test() ->
    Children = gnomon_sup:children(8),
    ?assertMatch([#{id := gnomon_clock, shutdown := 5000}], Children),
    ?assertEqual(ok, supervisor:check_childspecs(Children)),
    ?assertEqual([], gnomon_sup:children(4)).

app_file_test() ->
    _ = application:load(gnomon),
    ?assertEqual({ok, {gnomon_app, []}}, application:get_key(gnomon, mod)),
    {ok, Registered} = application:get_key(gnomon, registered),
    ?assertEqual([gnomon_clock, gnomon_sup], lists:sort(Registered)).

app_serves_the_date() ->
    ?assert(is_integer(persistent_term:get(?KEY, undefined))),
    assert_served(fun gnomon:date/0).

app_supervises_one_registered_clock() ->
    Clock = whereis(gnomon_clock),
    ?assert(is_pid(Clock)),
    ?assert(is_pid(whereis(gnomon_sup))),
    ?assertEqual(
        [{gnomon_clock, Clock, worker, [gnomon_clock]}], supervisor:which_children(gnomon_sup)
    ),
    ?assertEqual({error, {already_started, Clock}}, gnomon_clock:start_link()).

app_stop_erases_the_key() ->
    ok = application:stop(gnomon),
    ?assertEqual(undefined, whereis(gnomon_clock)),
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
    %% Readers keep working through the fallback.
    assert_now(fun gnomon:date/0).

%% exit(Pid, kill) skips terminate/2; the restart rewrites the value. The
%% supervisor is held so the key can be cleared between kill and restart,
%% which proves the restart wrote it.
killed_clock_is_restarted_with_the_value() ->
    Old = whereis(gnomon_clock),
    Ref = monitor(process, Old),
    ok = sys:suspend(gnomon_sup),
    true = exit(Old, kill),
    receive
        {'DOWN', Ref, process, Old, killed} -> ok
    after 1000 ->
        error(clock_did_not_die)
    end,
    gnomon:clear(),
    ?assertEqual(undefined, whereis(gnomon_clock)),
    ok = sys:resume(gnomon_sup),
    %% The supervisor answers this call only after the queued restart.
    [{gnomon_clock, New, worker, _}] = supervisor:which_children(gnomon_sup),
    ?assert(is_pid(New)),
    ?assert(is_integer(persistent_term:get(?KEY, undefined))),
    assert_served(fun gnomon:date/0).

terminate_child_erases_and_restart_child_restores() ->
    ok = supervisor:terminate_child(gnomon_sup, gnomon_clock),
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
    assert_now(fun gnomon:date/0),
    {ok, _} = supervisor:restart_child(gnomon_sup, gnomon_clock),
    ?assert(is_integer(persistent_term:get(?KEY, undefined))),
    assert_served(fun gnomon:date/0).

%% Killing the clock past the supervisor's intensity stops the application;
%% stop/1 erases the key so readers fall back instead of serving a frozen date.
clock_dying_past_intensity_stops_the_app_and_erases() ->
    Sup = whereis(gnomon_sup),
    Ref = monitor(process, Sup),
    ok = kill_clock_until_down(Ref, Sup, 30),
    ?assert(
        wait_until(
            fun() -> not lists:keymember(gnomon, 1, application:which_applications()) end, 2000
        )
    ),
    ?assertEqual(undefined, whereis(gnomon_clock)),
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
    assert_now(fun gnomon:date/0).

kill_clock_until_down(_Ref, _Sup, 0) ->
    error(supervisor_did_not_give_up);
kill_clock_until_down(Ref, Sup, N) ->
    case whereis(gnomon_clock) of
        undefined -> ok;
        Pid -> true = exit(Pid, kill)
    end,
    receive
        {'DOWN', Ref, process, Sup, _} -> ok
    after 50 ->
        kill_clock_until_down(Ref, Sup, N - 1)
    end.

app_runs_no_clock() ->
    ?assert(is_pid(whereis(gnomon_sup))),
    ?assertEqual([], supervisor:which_children(gnomon_sup)),
    ?assertEqual(undefined, whereis(gnomon_clock)),
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
    assert_now(fun gnomon:date/0).

app_stops_without_a_clock() ->
    ok = application:stop(gnomon),
    ?assertEqual(undefined, whereis(gnomon_sup)),
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
    assert_now(fun gnomon:date/0).

%%--------------------------------------------------------------------
%% Start order
%%--------------------------------------------------------------------

init(Children) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.

clock_spec() ->
    #{
        id => gnomon_clock,
        start => {gnomon_clock, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [gnomon_clock]
    }.

%% A sibling started after the clock sees the value in its own init/1.
value_exists_before_next_child_starts_test() ->
    gnomon:clear(),
    TestPid = self(),
    Probe = #{
        id => probe,
        start => {proc_lib, start_link, [?MODULE, probe_init, [TestPid]]},
        restart => temporary,
        shutdown => 100,
        type => worker,
        modules => [?MODULE]
    },
    {ok, Sup} = supervisor:start_link(?MODULE, [clock_spec(), Probe]),
    receive
        {probe_saw, Seen} -> ?assert(is_integer(Seen))
    after 5000 ->
        error(probe_did_not_report)
    end,
    MRef = monitor(process, Sup),
    unlink(Sup),
    exit(Sup, shutdown),
    receive
        {'DOWN', MRef, process, Sup, _} -> ok
    after 5000 ->
        error(supervisor_did_not_stop)
    end,
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)).

probe_init(TestPid) ->
    TestPid ! {probe_saw, persistent_term:get(?KEY, undefined)},
    proc_lib:init_ack({ok, self()}),
    receive
        stop -> ok
    end.

%%--------------------------------------------------------------------
%% Helpers
%%--------------------------------------------------------------------

wait_for_change(P1) ->
    Deadline = erlang:monotonic_time(millisecond) + ?TICK_DEADLINE_MS,
    wait_for_change(P1, Deadline).

wait_for_change(P1, Deadline) ->
    case persistent_term:get(?KEY, undefined) of
        P1 ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    error(value_did_not_change);
                false ->
                    timer:sleep(1),
                    wait_for_change(P1, Deadline)
            end;
        P2 ->
            P2
    end.

wait_until(Fun, TimeoutMs) ->
    Deadline = erlang:monotonic_time(millisecond) + TimeoutMs,
    wait_until_loop(Fun, Deadline).

wait_until_loop(Fun, Deadline) ->
    case Fun() of
        true ->
            true;
        false ->
            case erlang:monotonic_time(millisecond) > Deadline of
                true ->
                    false;
                false ->
                    timer:sleep(5),
                    wait_until_loop(Fun, Deadline)
            end
    end.

%% For the fallback path: the two clock reads may straddle a second
%% boundary, so accept either second.
assert_now(Fun) ->
    T0 = erlang:system_time(second),
    Got = Fun(),
    T1 = erlang:system_time(second),
    ?assert(
        lists:member(Got, [
            prop_gnomon:reference(T0),
            prop_gnomon:reference(T1)
        ])
    ).

%% For a value served by a running worker: the worker writes a second at
%% its tick, one millisecond or more after the boundary, so a read just
%% after a boundary legitimately sees the previous second.
assert_served(Fun) ->
    T0 = erlang:system_time(second),
    Got = Fun(),
    T1 = erlang:system_time(second),
    ?assert(
        lists:member(Got, [
            prop_gnomon:reference(T)
         || T <- lists:seq(T0 - 1, T1)
        ])
    ).
