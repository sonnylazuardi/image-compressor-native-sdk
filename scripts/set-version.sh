#!/usr/bin/env bash
# Bump .version in app.zon to match a release tag (no leading v).
set -Eeuo pipefail

version="${1:-}"
version="${version#v}"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'usage: %s <major.minor.patch>\n' "$0" >&2
  exit 2
fi

VERSION="$version" perl -0pi -e 's/(\.version = ")[^"]+(")/$1$ENV{VERSION}$2/' app.zon

printf 'set app.zon version to %s\n' "$version"
