#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
web_dir="$script_dir/../Web/Excalidraw"

cd "$web_dir"
npm ci
npm run build
