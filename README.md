# gnomon

HTTP `Date` header values served from a persistent term instead of an ETS
table.

`gnomon` keeps the current
[IMF-fixdate](https://www.rfc-editor.org/rfc/rfc9110#section-5.6.7)
(`Sun, 06 Nov 1994 08:49:37 GMT`, always 29 bytes) packed into one small
integer in a persistent term. A worker refreshes it once per second. Readers
unpack the integer and assemble the binary from seven fixed-width integer
segments taken from literal tables, so a read is one persistent-term lookup
and one small binary on the caller's heap.

## Usage

Add the dependency to `rebar.config`:

```erlang
{deps, [{gnomon, "1.0.0"}]}.
```

List `gnomon` in your application's `.app.src`, so it starts before the
first request is served:

```erlang
{applications, [kernel, stdlib, gnomon]}
```

From Elixir the dependency alone is enough; Mix starts it:

```elixir
{:gnomon, "~> 1.0"}
```

From Gleam, `gleam add gnomon` is enough; the value is ASCII, so bind it
as a `String`:

```gleam
@external(erlang, "gnomon", "date")
pub fn date() -> String
```

The application runs one clock process under its own supervisor. Read the
date wherever the header is built:

```erlang
1> gnomon:date().
<<"Sun, 06 Nov 1994 08:49:37 GMT">>
```

When the application is not running, `date/0` computes the date from the
system clock. That is correct but slower.

`gnomon:format/1` formats any Unix time in years 0 through 9999 the same way,
for `Last-Modified` and `Expires` style headers:

```erlang
2> gnomon:format(784111777).
<<"Sun, 06 Nov 1994 08:49:37 GMT">>
```

## Why not ETS

The usual design, which `cowboy_clock` and mist both use, is a process that
formats the date once per second into a protected ETS table with
`read_concurrency`, and readers that call `ets:lookup_element/3`. That works,
but the binary those clocks build is off-heap on current OTP releases, so
every lookup copies a reference to it and increments a reference count that
every reader shares, and the benchmark shows ten concurrent readers
contending on that count.

Reading a persistent term is a constant-time lookup with no locks and no
copying; the caller gets a pointer. The catch is on the write side. Replacing
or erasing a persistent term normally triggers a global garbage collection
pass in which every process scans its heap for the old value. At one update
per second that would scan every connection process every second. The
exception is a value that fits in one machine word, an immediate, which the
runtime updates and erases with no global pass.

So `gnomon` stores a small integer that packs the date fields:

| Field | Bits | Shift |
|---|---:|---:|
| Second | 6 | 0 |
| Minute | 6 | 6 |
| Hour | 5 | 12 |
| Weekday (0 = Monday) | 3 | 17 |
| Day of month | 5 | 20 |
| Month | 4 | 25 |
| Year (0 to 9999) | 14 | 29 |

That is 43 bits, well inside the 59 usable bits of a small integer on
64-bit BEAM. Because every field lives in one word, a read is always
consistent; there are no torn reads across fields. The persistent term is
read once per request and never held, so there is nothing for a global GC to
find even if one ran.

Readers unpack the integer with `bsr` and `band`. Each field indexes a
literal tuple in `src/gnomon_tables.hrl` that holds the field's ASCII bytes,
separator included, as an integer, and `date/0` assembles the 29-byte
binary from those seven fixed-width integer segments. The compiler knows
the total size, so the result is a small binary on the caller's heap, and
each segment is written as a word.

Measured under load, with every scheduler busy or with 100,000 processes
sharing them, a `date/0` read costs 21 to 28 ns of scheduler time across
runs, against 840 to 940 ns for the ETS lookup Cowboy and mist do today.
On one core it is 11 to 15 ns against about 20.

Finally, the two designs fail differently. An ETS table disappears with its
owner, so a crashed clock is visible at once. A persistent term outlives its
writer, so `gnomon_clock` erases the key in `terminate/2` and readers fall
back to the system clock while the key is absent.

## Limits

- 64-bit emulators only. On a 32-bit emulator, such as the 32-bit
  Raspberry Pi OS, the packed value is a bignum rather than an immediate
  and every update triggers a global GC pass. Output stays correct;
  `gnomon_clock` logs a warning at startup, and the property test
  `prop_pack_is_immediate` fails there on purpose.
- Years 0 through 9999. `pack/1` and `format/1` fail with `function_clause`
  outside that range.
- The year table covers 2000 through 2199. Other years take a slower path
  that formats the year on the fly, which is still correct and zero padded.
- A clock killed without running `terminate/2` leaves its last value in
  place until the supervisor's restart rewrites it. If the clock keeps
  dying and the supervisor gives up, the application stops and its
  `stop/1` erases the key.
- Ticks aim one millisecond past the system-clock second boundary with an
  absolute monotonic timer, so they do not drift. The runtime never fires a
  timer early, so the stored value lags the wall clock by at most a few
  milliseconds on an unloaded system.

## Supported Erlang/OTP

CI runs on OTP 27, 28, and 29, the floor shared by Cowboy 2.20 and mist 6.
Nothing in the library needs anything newer than OTP 21.3
(`persistent_term:get/2` with a default), but older releases are not
tested.

## Benchmarks

`bench/README.md` compares `date/0` with two ETS clocks, the real
`cowboy_clock`, whose binary is off-heap, and one holding an on-heap
binary, the pattern Bandit uses, from one worker up to one per scheduler,
with 100,000 workers, and in erlperf's timed mode.

On an Apple M5 with OTP 29 and the JIT, with all ten schedulers busy or
with 100,000 workers sharing them, a `date/0` read costs 21 to 28 ns of
scheduler time across three runs; the ETS clock holding an on-heap binary,
Bandit's pattern, 55 to 64 ns; and `cowboy_clock`, whose binary is
off-heap, 840 to 940 ns, because every read bumps a reference count that
all readers share. On one core it is 11 to 15 ns against about 20 for
either ETS clock. The results file has the full tables. Run it yourself
with:

```bash
bench/run.sh
```

## Development

```bash
rebar3 eunit
rebar3 proper -n 2000
rebar3 dialyzer
rebar3 xref
rebar3 fmt --check
rebar3 ex_doc
```

The code is formatted with [erlfmt](https://github.com/WhatsApp/erlfmt).

### Publishing

Releases go to Hex from a checkout of the tagged commit:

```bash
rebar3 hex user auth
rebar3 hex build
rebar3 hex publish
```

## License

Apache-2.0. See `LICENSE.md`.
