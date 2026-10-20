-module(gnomon_tests).

-include_lib("eunit/include/eunit.hrl").
-include("gnomon_tables.hrl").

-define(KEY, gnomon_date).
-define(MIN_SECONDS, -62167219200).
-define(MAX_SECONDS, 253402300799).

%% Verified vectors from the spec, covering the year-table edges
%% (1999, 2000, 2199, 2200), a leap day, the 2100 non-leap year, and the
%% maximum year.
vectors() ->
    [
        {0, <<"Thu, 01 Jan 1970 00:00:00 GMT">>},
        {784111777, <<"Sun, 06 Nov 1994 08:49:37 GMT">>},
        {946684799, <<"Fri, 31 Dec 1999 23:59:59 GMT">>},
        {946684800, <<"Sat, 01 Jan 2000 00:00:00 GMT">>},
        {951782400, <<"Tue, 29 Feb 2000 00:00:00 GMT">>},
        {4107542399, <<"Sun, 28 Feb 2100 23:59:59 GMT">>},
        {4107542400, <<"Mon, 01 Mar 2100 00:00:00 GMT">>},
        {7258118399, <<"Tue, 31 Dec 2199 23:59:59 GMT">>},
        {7258118400, <<"Wed, 01 Jan 2200 00:00:00 GMT">>},
        {253402300799, <<"Fri, 31 Dec 9999 23:59:59 GMT">>}
    ].

%%--------------------------------------------------------------------
%% format/1 and pack/1
%%--------------------------------------------------------------------

format_vectors_test_() ->
    [
        {binary_to_list(Expected), ?_assertEqual(Expected, gnomon:format(T))}
     || {T, Expected} <- vectors()
    ].

format_vectors_agree_with_reference_test_() ->
    [?_assertEqual(Expected, prop_gnomon:reference(T)) || {T, Expected} <- vectors()].

format_is_always_29_bytes_test_() ->
    [?_assertEqual(29, byte_size(gnomon:format(T))) || {T, _} <- vectors()].

%% Years 0 and 9999 use the cold year path and must be zero padded.
format_year_zero_test() ->
    ?assertEqual(<<"Sat, 01 Jan 0000 00:00:00 GMT">>, gnomon:format(?MIN_SECONDS)),
    ?assertEqual(prop_gnomon:reference(?MIN_SECONDS), gnomon:format(?MIN_SECONDS)).

format_negative_seconds_test() ->
    ?assertEqual(<<"Wed, 31 Dec 1969 23:59:59 GMT">>, gnomon:format(-1)).

%% The binary is built from fixed-size segments, so it is an on-heap
%% binary, not an off-heap one with a reference count. The distinction
%% matters when the value is stored in ETS and read concurrently; see
%% "Why not ETS" in README.md. Off-heap binaries show up in
%% process_info(self(), binary).
format_returns_on_heap_binary_test() ->
    erlang:garbage_collect(),
    {binary, Before} = process_info(self(), binary),
    ?assertEqual(<<"Tue, 29 Feb 2000 00:00:00 GMT">>, gnomon:format(951782400)),
    %% A cold year goes through io_lib and is still assembled on the heap.
    ?assertEqual(<<"Fri, 31 Dec 1999 23:59:59 GMT">>, gnomon:format(946684799)),
    {binary, After} = process_info(self(), binary),
    ?assertEqual(length(Before), length(After)).

pack_layout_test() ->
    %% Sun, 06 Nov 1994 08:49:37 GMT; Sunday is weekday 6.
    ?assertEqual(
        (1994 bsl 29) bor (11 bsl 25) bor (6 bsl 20) bor (6 bsl 17) bor
            (8 bsl 12) bor (49 bsl 6) bor 37,
        gnomon:pack(784111777)
    ),
    %% Thu, 01 Jan 1970; Thursday is weekday 3.
    ?assertEqual(
        (1970 bsl 29) bor (1 bsl 25) bor (1 bsl 20) bor (3 bsl 17),
        gnomon:pack(0)
    ).

%% An immediate on 64-bit words, a bignum on 32-bit words. Year 0 packs
%% below 2^27, so it is an immediate on both.
pack_is_immediate_iff_64_bit_test_() ->
    [?_assert(prop_gnomon:immediate_iff_64_bit(gnomon:pack(T))) || {T, _} <- vectors()] ++
        [?_assertEqual(0, erts_debug:flat_size(gnomon:pack(?MIN_SECONDS)))].

%% The spec's stated maximum has every field at its limit. The real
%% maximum date is a Friday, so it packs slightly lower.
pack_maximum_test() ->
    ?assert(gnomon:pack(?MAX_SECONDS) =< 5368608292603),
    ?assert(gnomon:pack(?MAX_SECONDS) < (1 bsl 43)),
    ?assertEqual(0, gnomon:pack(?MIN_SECONDS) bsr 29).

pack_rejects_out_of_range_test() ->
    ?assertError(function_clause, gnomon:pack(?MAX_SECONDS + 1)),
    ?assertError(function_clause, gnomon:pack(?MIN_SECONDS - 1)),
    ?assertError(function_clause, gnomon:pack(1.0)),
    ?assertError(function_clause, gnomon:pack(now)).

%%--------------------------------------------------------------------
%% date/0, update/0, clear/0
%%--------------------------------------------------------------------

read_test_() ->
    {foreach, fun() -> gnomon:clear() end, fun(_) -> gnomon:clear() end, [
        fun fallback_date/0,
        fun update_then_read/0,
        fun update_writes_an_immediate_iff_64_bit/0,
        fun clear_erases/0,
        fun clear_is_idempotent/0,
        fun date_is_flat_binary/0,
        fun date_is_on_heap/0
    ]}.

fallback_date() ->
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)),
    assert_now(fun gnomon:date/0).

update_then_read() ->
    T0 = erlang:system_time(second),
    ok = gnomon:update(),
    T1 = erlang:system_time(second),
    P = persistent_term:get(?KEY),
    ?assert(is_integer(P)),
    ?assert(lists:member(P, [gnomon:pack(T0), gnomon:pack(T1)])),
    ?assert(lists:member(gnomon:date(), [prop_gnomon:reference(T0), prop_gnomon:reference(T1)])),
    %% The stored value is served as is, so a stale value is visible: that
    %% is why the clock must erase it on shutdown.
    persistent_term:put(?KEY, gnomon:pack(784111777)),
    ?assertEqual(<<"Sun, 06 Nov 1994 08:49:37 GMT">>, gnomon:date()).

update_writes_an_immediate_iff_64_bit() ->
    ok = gnomon:update(),
    ?assert(prop_gnomon:immediate_iff_64_bit(persistent_term:get(?KEY))).

clear_erases() ->
    ok = gnomon:update(),
    ?assert(is_integer(persistent_term:get(?KEY, undefined))),
    ?assertEqual(ok, gnomon:clear()),
    ?assertEqual(undefined, persistent_term:get(?KEY, undefined)).

clear_is_idempotent() ->
    ?assertEqual(ok, gnomon:clear()),
    ?assertEqual(ok, gnomon:clear()).

date_is_flat_binary() ->
    ok = gnomon:update(),
    D = gnomon:date(),
    ?assert(is_binary(D)),
    ?assertEqual(29, byte_size(D)),
    ?assertEqual(<<" GMT">>, binary:part(D, 25, 4)).

%% The served path is on-heap too, like format/1.
date_is_on_heap() ->
    ok = gnomon:update(),
    erlang:garbage_collect(),
    {binary, Before} = process_info(self(), binary),
    D = gnomon:date(),
    {binary, After} = process_info(self(), binary),
    ?assertEqual(29, byte_size(D)),
    ?assertEqual(length(Before), length(After)).

%% The two reads may straddle a second boundary, so accept either second.
assert_now(Fun) ->
    T0 = erlang:system_time(second),
    Got = Fun(),
    T1 = erlang:system_time(second),
    ?assert(lists:member(Got, [prop_gnomon:reference(T0), prop_gnomon:reference(T1)])).

%%--------------------------------------------------------------------
%% Literal tables
%%--------------------------------------------------------------------

%% Every entry of every table, checked against its formula: the big-endian
%% integer value of the field's ASCII bytes with its separator.

wdays_table_test() ->
    ?assertEqual(
        ints(["Mon, ", "Tue, ", "Wed, ", "Thu, ", "Fri, ", "Sat, ", "Sun, "]),
        tuple_to_list(?WDAYS_INT)
    ).

mdays_table_test() ->
    ?assertEqual(ints([pad2(D, " ") || D <- lists:seq(1, 31)]), tuple_to_list(?MDAYS_INT)).

months_table_test() ->
    ?assertEqual(
        ints([
            "Jan ",
            "Feb ",
            "Mar ",
            "Apr ",
            "May ",
            "Jun ",
            "Jul ",
            "Aug ",
            "Sep ",
            "Oct ",
            "Nov ",
            "Dec "
        ]),
        tuple_to_list(?MONTHS_INT)
    ).

years_table_test() ->
    ?assertEqual(
        ints([integer_to_list(Y) ++ " " || Y <- lists:seq(2000, 2199)]),
        tuple_to_list(?YEARS_INT)
    ).

minutes_and_hours_table_test() ->
    ?assertEqual(ints([pad2(N, ":") || N <- lists:seq(0, 59)]), tuple_to_list(?MINUTES_INT)),
    ?assertEqual(?MINUTES_INT, ?HOURS_INT).

seconds_table_test() ->
    ?assertEqual(ints([pad2(N, " GMT") || N <- lists:seq(0, 59)]), tuple_to_list(?SECONDS_INT)).

ints(Strings) ->
    [binary:decode_unsigned(list_to_binary(S)) || S <- Strings].

pad2(N, Suffix) ->
    lists:flatten(io_lib:format("~2..0B~s", [N, Suffix])).
