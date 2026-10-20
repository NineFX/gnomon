# Benchmark

`bench/run.sh` builds the `bench` profile and runs `gnomon_bench`, which
measures everything with [erlperf](https://github.com/max-au/erlperf).
Results print to the terminal; `quick` gives a short run, which is what CI
does. The latest full run is pasted at the bottom of this file.

## What it measures

- **`gnomon:date/0`** against two ETS clocks, with an empty loop as the
  floor: the real `cowboy_clock:rfc1123/0` with the `cowboy` application
  started, whose binary is off-heap, so every lookup bumps a reference
  count that all readers share; and `gnomon_bench_ets`, which holds an
  on-heap binary that each lookup copies instead, as Bandit's clock does.
  The harness checks where each clock's binary lives at startup and prints
  it in the header.
- **Scaling**: erlperf's concurrency estimation mode stepping from one
  worker to one per scheduler without stopping early, reported as calls
  per second over all workers and as nanoseconds per call per worker.
- **Many workers**: a continuous run with 100,000 erlperf workers sharing
  the schedulers, the shape of a BEAM web server with one process per
  connection. Its nanoseconds per call is scheduler time, the schedulers'
  combined time divided by the calls made.
- **Timed mode** at one worker, the lowest-overhead measurement erlperf has.

## Notes

- erlperf counts iterations with a `call_count` trace on the generated
  runner, a single counter every worker increments, which costs more than
  a 10 ns call. Each runner iteration is therefore a batch of 1,000 calls in
  a tight local loop, so that cost is spread over the batch. In erlperf's
  own tables, Iteration is per 1,000 calls; the per-call tables below them
  divide it out.
- Two thirds of an earlier version of the read was `persistent_term:get/2`
  itself, because the key was the tuple `{gnomon, date}`, which is hashed
  and compared on every read. The key is the atom `gnomon_date`, which
  cut the one-worker read from 25 ns to about 11 ns at the time.
- Timings are from one machine and move a few nanoseconds between runs
  with its other load. Re-run it on your own hardware before drawing
  conclusions for a deployment.

## Latest run

2026-10-20, full mode, `bench/run.sh` output verbatim.

```text
gnomon benchmark
================
Mode:                full
OTP:                 29, ERTS 17.0.4
Emulator:            opt, JIT enabled
Architecture:        aarch64-apple-darwin25.6.0, 64-bit words
Schedulers online:   10
CPU:                 Apple M5
Versions:            erlperf 2.3.0, cowboy 2.20.0
ETS binaries:        cowboy_clock off-heap, gnomon_bench_ets on-heap

Read path, erlperf, 1000 calls per iteration
============================================
Scaling: concurrency estimation from 1 to 10 workers in steps of 1, never stopping early; 5 sample(s) of 1 s after 1 warmup sample(s) per step. Many workers: 100,000 workers, same sampling. Timed: one worker, 5 measured run(s) of a fixed iteration count. In erlperf's tables Code is the runner and Iteration is per 1000 calls.

Scaling, calls per second over all workers:
Workers  ETS, off-heap binary (cowboy_clock)  ETS, on-heap binary  gnomon:date/0  Empty loop, the floor
-------------------------------------------------------------------------------------------------------
1                                 47,195,800           55,288,600     68,623,200          1,939,337,600
2                                 22,139,600          104,898,000    121,660,600          3,330,535,600
3                                 22,400,000          149,170,800    174,452,200          4,423,300,800
4                                 23,849,800          188,717,600    232,542,600          6,065,808,800
5                                 12,911,600          170,200,200    243,925,200          6,271,813,400
6                                 12,680,200          179,313,000    269,628,000          6,494,061,800
7                                 13,271,800          164,345,200    291,817,600          6,940,549,400
8                                 11,438,200          184,708,400    315,068,600          7,026,371,200
9                                 10,673,800          183,753,800    325,604,400          7,795,088,400
10                                10,655,000          180,162,400    353,423,200          7,985,192,000

Scaling, ns per call per worker:
Workers  ETS, off-heap binary (cowboy_clock)  ETS, on-heap binary  gnomon:date/0  Empty loop, the floor
-------------------------------------------------------------------------------------------------------
1                                       21.2                 18.1           14.6                    0.5
2                                       90.3                 19.1           16.4                    0.6
3                                      133.9                 20.1           17.2                    0.7
4                                      167.7                 21.2           17.2                    0.7
5                                      387.2                 29.4           20.5                    0.8
6                                      473.2                 33.5           22.3                    0.9
7                                      527.4                 42.6           24.0                    1.0
8                                      699.4                 43.3           25.4                    1.1
9                                      843.2                 49.0           27.6                    1.2
10                                     938.5                 55.5           28.3                    1.3

100,000 workers, erlperf report:
Code                                 ||   Samples       Avg   StdDev    Median      P99  Iteration    Rel
gnomon_bench:loop_empty(1000).   100000         5   7820 Ki    2.05%   7864 Ki  7998 Ki   12790 us   100%
gnomon_bench:loop_date(1000).    100000         5    368 Ki    1.71%    368 Ki   377 Ki     272 ms     5%
gnomon_bench:loop_ets(1000).     100000         5    174 Ki    0.97%    174 Ki   177 Ki     574 ms     2%
gnomon_bench:loop_cowboy(1000).  100000         5     11204    0.74%     11175    11339    8927 ms     0%

100,000 workers, per call (ns per call is scheduler time, 10 schedulers):
Case                                       calls/s  ns/call per scheduler
-------------------------------------------------------------------------
ETS, off-heap binary (cowboy_clock)     11,204,200                  892.5
ETS, on-heap binary                    174,378,000                   57.3
gnomon:date/0                          367,961,400                   27.2
Empty loop, the floor                7,820,448,200                    1.3

Timed mode, 1 worker, erlperf report:
Code                                ||   Samples       Avg   StdDev    Median      P99  Iteration    Rel
gnomon_bench:loop_date(1000).        1         5    968 ms    1.33%    965 ms   986 ms   15005 ns   100%
gnomon_bench:loop_ets(1000).         1         5    988 ms    0.93%    993 ms   997 ms   20063 ns    98%
gnomon_bench:loop_cowboy(1000).      1         5   1002 ms    1.16%   1002 ms  1017 ms   20935 ns    97%
gnomon_bench:loop_empty(1000).       1         5   1013 ms   31.07%    832 ms  1363 ms     709 ns    96%

Timed mode, 1 worker, per call:
Case                                 ns/call
--------------------------------------------
ETS, off-heap binary (cowboy_clock)     20.9
ETS, on-heap binary                     20.1
gnomon:date/0                           15.0
Empty loop, the floor                    0.7
```
