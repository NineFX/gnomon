# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-10-20

### Added

- `gnomon:date/0`: the current IMF-fixdate as a 29-byte binary, read from
  a packed small integer in a persistent term and built from fixed-width
  integer segments so it costs less than an ETS lookup and stays on the
  caller's heap.
- `gnomon:format/1` and `gnomon:pack/1` for arbitrary Unix times in years
  0 through 9999.
- `gnomon:update/0` and `gnomon:clear/0`, the clock's write and erase,
  for a server that runs the clock outside the application.
- The `gnomon` application: a supervisor running one `gnomon_clock`
  worker per node, a `gen_server` that refreshes the value once per second
  on the system-clock second boundary and erases it on shutdown. The
  application's `stop/1` erases it as well, so the value never outlives
  the application. On a 32-bit emulator no clock runs and each read
  computes the date.
- EUnit and PropEr tests, including a cross-check against cowlib's
  `cow_date:rfc7231/1`.
- An erlperf benchmark against the real `cowboy_clock`, whose binary is
  off-heap, and against an ETS clock holding an on-heap binary, with
  results in `bench/README.md`.

[Unreleased]: https://github.com/ninefx/gnomon/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ninefx/gnomon/releases/tag/v1.0.0
