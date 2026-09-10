#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

readonly head_sha="${HEAD_SHA:?HEAD_SHA must be the 40-char commit SHA being synced}"
readonly source_path="${SOURCE_PATH:?SOURCE_PATH must point at the checked-out source repository, holding its full history}"
readonly target_path="${TARGET_PATH:?TARGET_PATH must point at the checked-out target repository the files were mirrored into}"
readonly mirror_subdir="${MIRROR_SUBDIR:?MIRROR_SUBDIR must be the source subdirectory mirrored into the target, e.g. 'root-dir'}"

readonly mirror_prefix="${mirror_subdir}/"

if [[ ! "${head_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  fatal "HEAD_SHA is not a 40-char commit SHA: '${head_sha}'"
fi
[[ -d "${source_path}" ]] || fatal "SOURCE_PATH directory does not exist: '${source_path}'"
[[ -d "${target_path}" ]] || fatal "TARGET_PATH directory does not exist: '${target_path}'"

source_holds() {
  local tree_path="${1:?source_holds requires a path relative to the source repository}"

  git -C "${source_path}" cat-file -e "${head_sha}:${tree_path}" 2> /dev/null
  return "$?"
}

target_tracks() {
  local rel_path="${1:?target_tracks requires a path relative to the target repository}"

  git -C "${target_path}" rev-parse --quiet --verify "HEAD:${rel_path}" > /dev/null 2>&1
  return "$?"
}

# Removes the mirrored files the source deleted, and only those, so files the source
# never owned are left alone. '-m --first-parent' also reports the deletions that only
# a merge commit carries, and '--no-renames' reports the retired half of a rename.
remove_retired_files() {
  local tree_path rel_path file_path
  local -A handled_tree_paths=()
  local removed_count=0

  while IFS= read -r -d '' tree_path; do
    [[ -n "${tree_path}" ]] || continue
    [[ -z "${handled_tree_paths[${tree_path}]+set}" ]] || continue
    handled_tree_paths["${tree_path}"]=1

    if source_holds "${tree_path}"; then
      continue
    fi

    rel_path="${tree_path#"${mirror_prefix}"}"
    if ! target_tracks "${rel_path}"; then
      continue
    fi

    file_path="${target_path}/${rel_path}"
    if [[ ! -f "${file_path}" && ! -L "${file_path}" ]]; then
      continue
    fi

    rm -f -- "${file_path}" || fatal "Failed to remove '${file_path}'"
    removed_count=$((removed_count + 1))
    log "Removed '${rel_path}', retired from '${mirror_subdir}'."
  done < <(
    git -C "${source_path}" log --first-parent -m --diff-filter=D --no-renames \
      --format="" --name-only -z "${head_sha}" -- "${mirror_prefix}"
  )

  log "Removed ${removed_count} file(s) retired from '${mirror_subdir}'."
  return 0
}

remove_retired_files
