#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
manifest=$repository_root/Config/cef.json
architecture=${OTTO_CEF_ARCHITECTURE:-${MUSE_CEF_ARCHITECTURE:-$(uname -m)}}
destination=${OTTO_CEF_ROOT:-${MUSE_CEF_ROOT:-$repository_root/.build/cef/$architecture}}

case $architecture in
  arm64|x86_64) ;;
  *)
    print -u2 "Unsupported CEF architecture: $architecture"
    exit 2
    ;;
esac

archive_name=$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["archives"][sys.argv[2]]["name"])' \
  "$manifest" "$architecture")
expected_sha1=$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["archives"][sys.argv[2]]["sha1"])' \
  "$manifest" "$architecture")
source_url=$(/usr/bin/python3 -c \
  'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$manifest")
download_dir=$repository_root/.build/downloads
archive=$download_dir/$archive_name

/bin/mkdir -p "$download_dir" "${destination:h}"
if [[ ! -f $archive ]]; then
  /usr/bin/curl --fail --location --progress-bar "$source_url$archive_name" --output "$archive"
fi

actual_sha1=$(/usr/bin/shasum -a 1 "$archive" | /usr/bin/awk '{print $1}')
if [[ $actual_sha1 != $expected_sha1 ]]; then
  print -u2 "CEF archive checksum mismatch"
  exit 3
fi

/bin/rm -rf "$destination"
/bin/mkdir -p "$destination"
/usr/bin/tar -xjf "$archive" --strip-components=1 -C "$destination"
print "$destination"
