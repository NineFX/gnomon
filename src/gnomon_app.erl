%% @private
-module(gnomon_app).

-behavior(application).

-export([start/2, stop/1]).

-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_Type, _Args) ->
    case gnomon_sup:start_link() of
        {ok, Pid} -> {ok, Pid};
        {error, _} = Error -> Error
    end.

%% Runs whenever the application stops, including after its supervisor
%% gives up, so the value never outlives the application.
-spec stop(term()) -> ok.
stop(_State) ->
    gnomon:clear().
