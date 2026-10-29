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

2026-10-29, full mode, `bench/run.sh` output verbatim.

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
1                                 48,089,200           54,238,000     96,673,000          1,448,220,200
2                                 22,203,000           99,774,400    187,569,400          2,770,283,000
3                                 22,558,600          152,217,600    261,451,800          3,980,298,800
4                                 23,900,600          152,220,000    306,096,200          5,385,395,000
5                                 12,486,600          139,237,200    362,066,800          5,587,597,800
6                                 12,177,200          178,705,400    382,694,800          6,480,255,400
7                                 12,663,800          164,832,000    434,158,800          5,654,466,000
8                                 12,600,200          182,344,400    447,792,800          6,136,686,600
9                                 11,350,600          169,317,200    484,600,400          6,688,509,000
10                                11,529,000          176,628,000    501,972,600          7,127,109,400

Scaling, ns per call per worker:
Workers  ETS, off-heap binary (cowboy_clock)  ETS, on-heap binary  gnomon:date/0  Empty loop, the floor
-------------------------------------------------------------------------------------------------------
1                                       20.8                 18.4           10.3                    0.7
2                                       90.1                 20.0           10.7                    0.7
3                                      133.0                 19.7           11.5                    0.8
4                                      167.4                 26.3           13.1                    0.7
5                                      400.4                 35.9           13.8                    0.9
6                                      492.7                 33.6           15.7                    0.9
7                                      552.8                 42.5           16.1                    1.2
8                                      634.9                 43.9           17.9                    1.3
9                                      792.9                 53.2           18.6                    1.3
10                                     867.4                 56.6           19.9                    1.4

100,000 workers, erlperf report:
Code                                 ||   Samples       Avg   StdDev    Median      P99  Iteration    Rel
gnomon_bench:loop_empty(1000).   100000         5   7199 Ki    4.87%   7338 Ki  7598 Ki   13895 us   100%
gnomon_bench:loop_date(1000).    100000         5    500 Ki    3.95%    503 Ki   523 Ki     200 ms     7%
gnomon_bench:loop_ets(1000).     100000         5    171 Ki    1.48%    170 Ki   175 Ki     584 ms     2%
gnomon_bench:loop_cowboy(1000).  100000         5     10923    1.18%     10946    11088    9157 ms     0%

100,000 workers, per call (ns per call is scheduler time, 10 schedulers):
Case                                       calls/s  ns/call per scheduler
-------------------------------------------------------------------------
ETS, off-heap binary (cowboy_clock)     10,922,800                  915.5
ETS, on-heap binary                    171,391,000                   58.3
gnomon:date/0                          499,856,800                   20.0
Empty loop, the floor                7,198,518,000                    1.4

Timed mode, 1 worker, erlperf report:
Code                                ||   Samples       Avg   StdDev    Median      P99  Iteration    Rel
gnomon_bench:loop_cowboy(1000).      1         5    996 ms    1.29%    993 ms  1018 ms   20809 ns   100%
gnomon_bench:loop_date(1000).        1         5    997 ms    0.80%    996 ms  1010 ms   10172 ns   100%
gnomon_bench:loop_ets(1000).         1         5   1008 ms    1.33%   1009 ms  1020 ms   20355 ns    99%
gnomon_bench:loop_empty(1000).       1         5   1269 ms   27.86%   1109 ms  1894 ms     634 ns    78%

Timed mode, 1 worker, per call:
Case                                 ns/call
--------------------------------------------
ETS, off-heap binary (cowboy_clock)     20.8
ETS, on-heap binary                     20.4
gnomon:date/0                           10.2
Empty loop, the floor                    0.6
```
