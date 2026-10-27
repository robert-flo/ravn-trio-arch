#!/usr/bin/env bash

# Shared helpers for the tests/validate-*.sh host-side entry points.
#
# This file must be sourced, never executed directly. Source it after
# defining a script-local `usage()` function — parse_help_arg() calls
# whatever `usage` is currently defined in the sourcing script.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf 'ERROR: %s is a library and must be sourced, not executed.\n' "${BASH_SOURCE[0]}" >&2
  exit 2
fi

die() {
  printf 'ERROR: %s\n' "$1" >&2
  exit 2
}

# Handles the shared -h/--help/no-args/unexpected-arg contract used by
# every validator. Requires the caller to have already defined `usage()`.
parse_help_arg() {
  case "${1:-}" in
    -h | --help)
      usage
      exit 0
      ;;
    '') ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

require_docker() {
  command -v docker > /dev/null 2>&1 || die 'docker is required to run the isolated Arch validation.'
  docker info > /dev/null 2>&1 || die 'the Docker daemon is unavailable or the current user cannot access it.'
}
