%% @private
-module(gnomon_sup).

-behavior(supervisor).

-export([start_link/0]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Clock = #{
        id => gnomon_clock,
        start => {gnomon_clock, start_link, []},
        restart => permanent,
        % Not brutal_kill: terminate/2 must run to erase the persistent term.
        shutdown => 5000,
        type => worker,
        modules => [gnomon_clock]
    },
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, [Clock]}}.
