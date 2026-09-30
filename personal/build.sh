#!/usr/bin/env bash
set -euo pipefail

# Run from the repository root. ZIG can point to an existing Zig 0.15.2.
if [[ -n ${ZIG:-} ]]; then
  zig_cmd=("$ZIG")
else
  zig_cmd=(uv run --no-project --with ziglang==0.15.2 python -m ziglang)
fi
if [[ $("${zig_cmd[@]}" version) != 0.15.2 ]]; then
  echo 'Ghostty 1.3.1 requires Zig 0.15.2.' >&2
  exit 1
fi
"${zig_cmd[@]}" build -Doptimize=ReleaseFast -Dapp-runtime=gtk \
  -Demit-docs=false -Demit-terminfo=false -Demit-termcap=false \
  -fno-sys=gtk4-layer-shell -j2 "$@"
