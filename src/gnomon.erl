%% @doc HTTP `Date' header values served from a persistent term.
%%
%% The current date is stored as one small integer in a persistent term.
%% On 64-bit BEAM a small integer is an immediate, so the once-per-second
%% update and the erase on shutdown never trigger the global garbage
%% collection pass that persistent terms normally cause. Readers unpack the
%% integer with `bsr' and `band' and assemble the 29-byte value from five
%% fixed-width integer segments taken from literal tables, so a read is one
%% persistent-term lookup and one small binary on the caller's heap.
%%
%% The `gnomon' application runs {@link gnomon_clock}, which keeps the
%% value fresh. When no clock is running, on a 32-bit emulator or outside
%% the application, readers compute the date from the system clock, which
%% is correct but slower.
%%
%% The packed layout, from the least significant bit:
%% ```
%% second  6 bits  shift  0
%% minute  6 bits  shift  6
%% hour    5 bits  shift 12
%% weekday 3 bits  shift 17   0 = Monday
%% day     5 bits  shift 20   1..31
%% month   4 bits  shift 25   1..12
%% year   14 bits  shift 29   0..9999
%% '''
-module(gnomon).

-export([date/0, date/1, stamp/0, format/1, pack/1, update/0, clear/0]).
-export_type([stamp/0]).

%% One second packed as described above; an immediate on 64-bit words.
-type stamp() :: non_neg_integer().

-include("gnomon_tables.hrl").

%% The persistent term key. Private to this module; hosts go through
%% update/0 and clear/0. An atom rather than a {module, name} tuple:
%% persistent_term:get/2 hashes and compares the key on every read, and a
%% tuple key measured about 14 ns slower per read than an atom at one
%% worker; see bench/README.md.
-define(KEY, gnomon_date).

%% Unix seconds for 0000-01-01T00:00:00Z and 9999-12-31T23:59:59Z, the
%% range the packed layout can represent.
-define(MIN_SECONDS, -62167219200).
-define(MAX_SECONDS, 253402300799).

%% @doc The current IMF-fixdate as a 29-byte binary, for example
%% `<<"Sun, 06 Nov 1994 08:49:37 GMT">>'. This is the hot path.
%%
%% A binary is valid iodata and valid chardata; an API that insists on a
%% list can take `[gnomon:date()]'. The binary is built from five
%% fixed-width integer segments, each one or two fields' ASCII bytes as an
%% integer from a literal table. The compiler knows the total size, so the
%% result lives on the caller's heap rather than off-heap with a reference
%% count, and each segment is written as a word rather than copied from a
%% binary. This measured faster than an improper-list iodata form, than
%% `iolist_to_binary/1' over such a list, than a variable-size
%% construction and than fixed-size binary segments when the library was
%% written.
%%
%% Reads the packed value from the persistent term. If no {@link gnomon_clock}
%% is running the value is computed from the system clock instead.
-spec date() -> binary().
date() ->
    case persistent_term:get(?KEY, undefined) of
        undefined -> to_binary(pack(erlang:system_time(second)));
        P -> to_binary(P)
    end.

%% @doc The packed second the clock last wrote, or `undefined' when no
%% clock is running. One persistent-term read, so a connection process can
%% compare it on every response and cache a whole header line keyed on it;
%% see the README.
-spec stamp() -> stamp() | undefined.
stamp() ->
    persistent_term:get(?KEY, undefined).

%% @doc The IMF-fixdate for a stamp from {@link stamp/0} or {@link pack/1}.
-spec date(stamp()) -> binary().
date(Stamp) ->
    to_binary(Stamp).

%% @doc Formats the given Unix time (seconds since the epoch, UTC) as a
%% 29-byte IMF-fixdate binary, the same shape as {@link date/0}.
%%
%% Valid for years 0 through 9999. Years outside 2000 to 2199 take a slower
%% path that formats the year on the fly.
-spec format(integer()) -> binary().
format(UnixSeconds) ->
    to_binary(pack(UnixSeconds)).

%% @doc Packs the given Unix time into the small integer this library stores
%% in its persistent term.
-spec pack(integer()) -> stamp().
pack(UnixSeconds) when
    is_integer(UnixSeconds),
    UnixSeconds >= ?MIN_SECONDS,
    UnixSeconds =< ?MAX_SECONDS
->
    {{Y, Mo, D}, {H, Mi, S}} =
        calendar:system_time_to_universal_time(UnixSeconds, second),
    W = calendar:day_of_the_week(Y, Mo, D) - 1,
    (Y bsl 29) bor (Mo bsl 25) bor (D bsl 20) bor (W bsl 17) bor
        (H bsl 12) bor (Mi bsl 6) bor S.

%% @doc Writes the packed value for the current system time.
%% {@link gnomon_clock} calls this once per second. A clock run instead of
%% the application must call {@link clear/0} when it stops, or readers keep
%% serving a frozen date.

-spec update() -> ok.
update() ->
    persistent_term:put(?KEY, pack(erlang:system_time(second))).

%% @doc Erases the persistent term.
-spec clear() -> ok.
clear() ->
    _ = persistent_term:erase(?KEY),
    ok.

%%--------------------------------------------------------------------
%% Internal
%%--------------------------------------------------------------------

%% Every segment is a fixed-width integer, so the total size is known at
%% compile time, the result is allocated on the heap, and each segment is
%% written as a word instead of being copied from a binary.
-spec to_binary(non_neg_integer()) -> <<_:232>>.
to_binary(P) ->
    <<
        (element(((P bsr 17) band 7) + 1, ?WDAYS_INT)):40,
        (element(((P bsr 20) band 511) + 1, ?DAYMONTHS_INT)):56,
        (year(P bsr 29)):40,
        (element(((P bsr 6) band 2047) + 1, ?HOURMINS_INT)):48,
        (element((P band 63) + 1, ?SECONDS_INT)):48
    >>.

-spec year(non_neg_integer()) -> non_neg_integer().
year(Y) when Y >= 2000, Y =< 2199 ->
    element(Y - 1999, ?YEARS_INT);
year(Y) ->
    year_cold(Y).

%% Years outside the table. Zero-padded to four digits as RFC 9110
%% requires, with the trailing separator baked in like the table entries.
-spec year_cold(non_neg_integer()) -> non_neg_integer().
year_cold(Y) ->
    binary:decode_unsigned(iolist_to_binary(io_lib:format("~4..0B ", [Y]))).
