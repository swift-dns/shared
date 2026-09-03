#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

readonly build_mode="${BUILD_MODE:?BUILD_MODE must be 'debug' or 'release'}"
readonly wasmtime_version="${WASMTIME_VERSION:?WASMTIME_VERSION must be a wasmtime release, e.g. '48.0.1'}"
readonly wasmtime_sha256="${WASMTIME_SHA256:?WASMTIME_SHA256 must be the sha256 of the x86_64-linux wasmtime tarball of that release}"
readonly test_flags="${TEST_FLAGS:-}"

case "${build_mode}" in
  debug | release) ;;
  *) fatal "BUILD_MODE must be 'debug' or 'release', got '${build_mode}'" ;;
esac

readonly build_dir=".build/wasm32-unknown-wasip1/${build_mode}"
readonly wasmtime_name="wasmtime-v${wasmtime_version}-x86_64-linux"
readonly wasmtime_root="${RUNNER_TEMP:-/tmp}"
readonly wasmtime="${wasmtime_root}/${wasmtime_name}/wasmtime"

install_wasmtime() {
  local tarball="${wasmtime_root}/${wasmtime_name}.tar.xz"

  log "Installing wasmtime ${wasmtime_version}."
  curl --silent --show-error --fail --location --output "${tarball}" \
    "https://github.com/bytecodealliance/wasmtime/releases/download/v${wasmtime_version}/${wasmtime_name}.tar.xz"
  printf -- '%s  %s\n' "${wasmtime_sha256}" "${tarball}" | sha256sum --check --quiet \
    || fatal "The wasmtime tarball does not match the pinned sha256"
  tar -xJf "${tarball}" -C "${wasmtime_root}"
  "${wasmtime}" --version
}

find_test_bundle() {
  local bundles
  bundles="$(find "${build_dir}" -maxdepth 1 -type f \( -name '*PackageTests.xctest' -o -name '*PackageTests.wasm' \))"
  [[ -n "${bundles}" ]] || fatal "No test bundle under '${build_dir}'; build with '--build-tests' first"
  [[ "$(printf -- '%s\n' "${bundles}" | wc -l)" -eq 1 ]] || fatal "More than one test bundle under '${build_dir}': ${bundles}"
  printf -- '%s' "${bundles}"
}

install_wasmtime

test_bundle="$(find_test_bundle)"
readonly test_bundle

# The bundle takes the same '--skip' and '--filter' patterns 'swift test' does.
IFS=' ' read -r -a test_flag_words <<< "${test_flags}"

log "Running ${test_bundle} with wasmtime."
"${wasmtime}" run --dir . "${test_bundle}" --testing-library swift-testing "${test_flag_words[@]}"
