%% @private
-module(gnomon_sup).

-behavior(supervisor).

-export([start_link/0, children/1]).
-export([init/1]).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Children = children(erlang:system_info(wordsize)),
    case Children of
        [] ->
            logger:notice(
                "gnomon: 32-bit emulator; the packed date is not an immediate, "
                "so no clock runs and each read computes the date"
            );
        _ ->
            ok
    end,
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, Children}}.

%% The packed value is an immediate only with 64-bit words.
-spec children(4 | 8) -> [supervisor:child_spec()].
children(8) ->
    [
        #{
            id => gnomon_clock,
            start => {gnomon_clock, start_link, []},
            restart => permanent,
            % Not brutal_kill: terminate/2 must run to erase the persistent term.
            shutdown => 5000,
            type => worker,
            modules => [gnomon_clock]
        }
    ];
children(_) ->
    [].
