#!/bin/sh

set -eu

README_PATH="${SRCROOT}/README.md"

if [ ! -f "${README_PATH}" ]; then
  exit 0
fi

tmp_file="$(mktemp)"

awk \
  -v version="${MARKETING_VERSION:-}" \
  -v build="${CURRENT_PROJECT_VERSION:-}" \
  '
  /<!-- VERSION_BLOCK_START -->/ {
    print
    print "- Version: `" version "`"
    print "- Build: `" build "`"
    skip = 1
    next
  }
  /<!-- VERSION_BLOCK_END -->/ {
    skip = 0
    print
    next
  }
  skip != 1 { print }
  ' "${README_PATH}" > "${tmp_file}"

mv "${tmp_file}" "${README_PATH}"
