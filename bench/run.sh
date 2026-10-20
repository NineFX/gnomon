#!/bin/sh
# Builds the bench profile and runs the benchmark harness. Results print to
# the terminal; bench/README.md keeps the latest run.
#   bench/run.sh          full run, about fifteen minutes
#   bench/run.sh quick    short run, for CI smoke testing
set -e
cd "$(dirname "$0")/.."
rebar3 as bench compile
exec erl -noshell -pa _build/bench/lib/*/ebin _build/bench/lib/gnomon/bench \
    -eval 'gnomon_bench:main(init:get_plain_arguments()), halt().' \
    -extra "$@"
