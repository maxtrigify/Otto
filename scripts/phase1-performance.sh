#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
scratch_path=${OTTO_PERFORMANCE_SCRATCH_PATH:-${MUSE_PERFORMANCE_SCRATCH_PATH:-$repository_root/.build/phase1-performance}}
iterations=${OTTO_BENCHMARK_ITERATIONS:-${MUSE_BENCHMARK_ITERATIONS:-20}}

[[ $scratch_path == $repository_root/.build/* ]] || {
  print -u2 "OTTO_PERFORMANCE_SCRATCH_PATH must remain inside the Otto .build directory."
  exit 2
}

OTTO_BENCHMARK_ITERATIONS=$iterations /usr/bin/swift run \
  --package-path "$repository_root" \
  --scratch-path "$scratch_path" \
  --disable-automatic-resolution \
  -c release \
  otto-performance
