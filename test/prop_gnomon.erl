%% Property tests for gnomon, run with `rebar3 proper`.
%%
%% reference/1 is an independent formatter built on calendar and
%% io_lib:format. It and immediate_iff_64_bit/1 are exported so the EUnit
%% modules can use them too.
-module(prop_gnomon).

-include_lib("proper/include/proper.hrl").

-export([reference/1, unix_seconds/0, immediate_iff_64_bit/1]).

%% 9999-12-31T23:59:59Z, the largest value pack/1 accepts.
-define(MAX_SECONDS, 253402300799).

%% The table edges, a leap day, the 2100 non-leap year, and the limits.
-define(EDGES, [
    0,
    784111777,
    946684799,
    946684800,
    951782400,
    4107542399,
    4107542400,
    7258118399,
    7258118400,
    2147483647,
    2147483648,
    4294967295,
    ?MAX_SECONDS
]).

%%--------------------------------------------------------------------
%% Properties
%%--------------------------------------------------------------------

prop_format_matches_reference() ->
    ?FORALL(
        T,
        unix_seconds(),
        gnomon:format(T) =:= reference(T)
    ).

%% cowlib is a test-only dependency; cow_date:rfc7231/1 is what Cowboy
%% itself uses to format the Date header.
prop_format_matches_cowlib() ->
    ?FORALL(
        T,
        unix_seconds(),
        gnomon:format(T) =:=
            cow_date:rfc7231(
                calendar:system_time_to_universal_time(T, second)
            )
    ).

%% date/0 serves the stored packed value, so check that path over the
%% whole domain too. The private key is written directly and cleared
%% afterwards.
prop_date_matches_reference() ->
    ?FORALL(
        T,
        unix_seconds(),
        begin
            persistent_term:put(gnomon_date, gnomon:pack(T)),
            Result = gnomon:date() =:= reference(T),
            ok = gnomon:clear(),
            Result
        end
    ).

%% On 64-bit words the packed value is an immediate, so the once-per-second
%% persistent_term:put/2 never triggers a global GC. On 32-bit words it is
%% a bignum, which is why the application starts no clock there.
prop_pack_is_immediate_iff_64_bit() ->
    ?FORALL(T, unix_seconds(), immediate_iff_64_bit(gnomon:pack(T))).

prop_pack_fits_in_43_bits() ->
    ?FORALL(
        T,
        unix_seconds(),
        begin
            P = gnomon:pack(T),
            P >= 0 andalso P < (1 bsl 43)
        end
    ).

prop_output_is_29_bytes() ->
    ?FORALL(T, unix_seconds(), byte_size(gnomon:format(T)) =:= 29).

%% Unpacking the fields gives back what calendar computed.
prop_pack_fields_roundtrip() ->
    ?FORALL(
        T,
        unix_seconds(),
        begin
            {{Y, Mo, D}, {H, Mi, S}} =
                calendar:system_time_to_universal_time(T, second),
            W = calendar:day_of_the_week(Y, Mo, D) - 1,
            P = gnomon:pack(T),
            {Y, Mo, D, W, H, Mi, S} =:=
                {
                    P bsr 29,
                    (P bsr 25) band 15,
                    (P bsr 20) band 31,
                    (P bsr 17) band 7,
                    (P bsr 12) band 31,
                    (P bsr 6) band 63,
                    P band 63
                }
        end
    ).

%% Later instants pack to larger integers, so readers can compare values.
prop_pack_is_monotonic() ->
    ?FORALL(
        {T1, T2},
        {unix_seconds(), unix_seconds()},
        case T1 < T2 of
            true -> gnomon:pack(T1) < gnomon:pack(T2);
            false -> gnomon:pack(T1) >= gnomon:pack(T2)
        end
    ).

%%--------------------------------------------------------------------
%% Generators
%%--------------------------------------------------------------------

%% Weighted toward the ranges that matter in practice while still covering
%% the whole domain and the known edges.
unix_seconds() ->
    frequency([
        {6, integer(0, ?MAX_SECONDS)},
        {4, integer(0, 4294967295)},
        {3, integer(946684800, 7258118399)},
        {1, oneof(?EDGES)}
    ]).

%%--------------------------------------------------------------------
%% Reference formatter
%%--------------------------------------------------------------------

-spec reference(integer()) -> binary().
reference(T) ->
    {{Y, Mo, D}, {H, Mi, S}} = calendar:system_time_to_universal_time(T, second),
    Wday = element(
        calendar:day_of_the_week(Y, Mo, D),
        {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}
    ),
    Month = element(
        Mo, {"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
    ),
    iolist_to_binary(
        io_lib:format(
            "~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT",
            [Wday, D, Month, Y, H, Mi, S]
        )
    ).

%%--------------------------------------------------------------------
%% Word size
%%--------------------------------------------------------------------

%% An immediate on 64-bit words, a bignum on 32-bit words.
-spec immediate_iff_64_bit(integer()) -> boolean().
immediate_iff_64_bit(P) ->
    case erlang:system_info(wordsize) of
        8 -> erts_debug:flat_size(P) =:= 0;
        4 -> erts_debug:flat_size(P) > 0
    end.
