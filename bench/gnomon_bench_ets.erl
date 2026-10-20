%% ETS clock holding an on-heap binary
-module(gnomon_bench_ets).

-behavior(gen_server).

-export([start_link/0, rfc1123/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec rfc1123() -> binary().
rfc1123() ->
    try
        ets:lookup_element(?MODULE, rfc1123, 2)
    catch
        error:badarg ->
            on_heap_now()
    end.

init([]) ->
    ?MODULE = ets:new(?MODULE, [set, protected, named_table, {read_concurrency, true}]),
    true = ets:insert(?MODULE, {rfc1123, on_heap_now()}),
    _ = erlang:send_after(1000, self(), update),
    {ok, undefined}.

handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(update, State) ->
    true = ets:insert(?MODULE, {rfc1123, on_heap_now()}),
    _ = erlang:send_after(1000, self(), update),
    {noreply, State};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

on_heap_now() ->
    binary:copy(cow_date:rfc7231(erlang:universaltime())).
