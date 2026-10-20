%% @doc Worker that refreshes the {@link gnomon} persistent term once per
%% second. The `gnomon' application supervises one per node on 64-bit
%% emulators.
%%
%% It traps exits so `terminate/2' erases the value on shutdown; a
%% persistent term outlives its writer, and a stale one is silently wrong.
%% After a kill the supervisor's restart rewrites it, and if the supervisor
%% gives up the application's `stop/1' erases it. A clock run instead of
%% the application takes on that cleanup itself.
%%
%% Ticks use an absolute timer aimed one millisecond past the next
%% system-clock second boundary, so they do not drift. The timer reference
%% is checked on expiry, so a stray `tick' message is ignored.
-module(gnomon_clock).

-behavior(gen_server).

-export([start_link/0]).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-type state() :: #{timer := reference()}.

%% @doc Starts the worker, linked to the caller and registered locally as
%% `gnomon_clock'. The persistent term is written before this returns.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @private
-spec init([]) -> {ok, state()}.
init([]) ->
    _ = process_flag(trap_exit, true),
    {Mono, Ms} = now_ms(),
    ok = gnomon:update(),
    {ok, #{timer => schedule(Mono, Ms)}}.

%% @private
-spec handle_call(term(), gen_server:from(), state()) ->
    {reply, ignored, state()}.
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

%% @private
-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
-spec handle_info(term(), state()) -> {noreply, state()}.
handle_info({timeout, Ref, tick}, #{timer := Ref} = State) ->
    {Mono, Ms} = now_ms(),
    ok = gnomon:update(),
    {noreply, State#{timer => schedule(Mono, Ms)}};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) ->
    gnomon:clear().

%% @private
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Both clocks are read before gnomon:update/0 runs. If a second boundary
%% falls between this read and the update, the next tick is aimed at that
%% boundary, which is already past, so it fires at once and rewrites the
%% same second through the equal-value fast path. Reading the clock after
%% the update could instead aim one second too far and leave a second
%% unwritten.
-spec now_ms() -> {integer(), integer()}.
now_ms() ->
    {erlang:monotonic_time(millisecond), erlang:system_time(millisecond)}.

%% Aim one millisecond past the next system-clock second boundary, as an
%% absolute monotonic time, so a slow tick does not push later ticks off
%% the boundary. start_timer/4 rather than send_after/4, so the expiry
%% message carries the reference that handle_info/2 checks.
-spec schedule(integer(), integer()) -> reference().
schedule(Mono, Ms) ->
    Next = Mono + (1000 - Ms rem 1000) + 1,
    erlang:start_timer(Next, self(), tick, [{abs, true}]).
