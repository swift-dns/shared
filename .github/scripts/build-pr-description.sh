#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

readonly repository="${REPOSITORY:?REPOSITORY must be the owner/name of the source repository, e.g. 'swift-dns/shared'}"
readonly server_url="${SERVER_URL:?SERVER_URL must be the GitHub server URL, e.g. 'https://github.com'}"
readonly head_sha="${HEAD_SHA:?HEAD_SHA must be the 40-char commit SHA being synced}"
readonly source_path="${SOURCE_PATH:?SOURCE_PATH must point at the checked-out source repository}"
readonly target_path="${TARGET_PATH:?TARGET_PATH must point at the checked-out target repository the files were mirrored into}"
readonly mirror_subdir="${MIRROR_SUBDIR:?MIRROR_SUBDIR must be the source subdirectory mirrored into the target, e.g. 'root-dir'}"
readonly commit_limit="${COMMIT_LIMIT:?COMMIT_LIMIT must be the maximum number of recent commits to scan for the last-synced one, e.g. '20'}"
readonly output_file="${OUTPUT_FILE:?OUTPUT_FILE must be the file path to write the pull request body to}"

readonly mirror_prefix="${mirror_subdir}/"

if [[ ! "${head_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  fatal "HEAD_SHA is not a 40-char commit SHA: '${head_sha}'"
fi
if [[ ! "${commit_limit}" =~ ^[1-9][0-9]*$ ]]; then
  fatal "COMMIT_LIMIT is not a positive integer: '${commit_limit}'"
fi
[[ -d "${source_path}" ]] || fatal "SOURCE_PATH directory does not exist: '${source_path}'"
[[ -d "${target_path}" ]] || fatal "TARGET_PATH directory does not exist: '${target_path}'"

declare -A target_blob_cache=()
target_blob() {
  local rel_path="${1:?target_blob requires a repo-relative path}"

  if [[ -z "${target_blob_cache[${rel_path}]+set}" ]]; then
    target_blob_cache["${rel_path}"]="$(
      git -C "${target_path}" rev-parse --quiet --verify "HEAD:${rel_path}" 2>/dev/null || true
    )"
  fi
  printf -- '%s' "${target_blob_cache[${rel_path}]}"
  return 0
}

snapshot_matches_target() {
  local commit_sha="${1:?snapshot_matches_target requires a commit SHA}"
  local tree_path rel_path source_blob

  while IFS= read -r -d '' tree_path; do
    rel_path="${tree_path#"${mirror_prefix}"}"
    source_blob="$(git -C "${source_path}" rev-parse --verify "${commit_sha}:${tree_path}")"
    if [[ "${source_blob}" != "$(target_blob "${rel_path}")" ]]; then
      return 1
    fi
  done < <(
    git -C "${source_path}" ls-tree -r -z --name-only "${commit_sha}" -- "${mirror_subdir}/"
  )
  return 0
}

collect_related_commits() {
  local commit_sha subject
  local related_count=0

  while IFS= read -r commit_sha; do
    [[ -n "${commit_sha}" ]] || continue

    if snapshot_matches_target "${commit_sha}"; then
      log "Last-synced from commit: ${commit_sha:0:7}; listing the ${related_count} new commit(s) since then:"
      return 0
    fi

    subject="$(git -C "${source_path}" show --no-patch --format=%s "${commit_sha}")"
    printf -- '- %s ([%s](%s/%s/commit/%s))\n' \
      "${subject}" "${commit_sha:0:7}" "${server_url}" "${repository}" "${commit_sha}"
    related_count=$((related_count + 1))
  done < <(
    git -C "${source_path}" log --max-count="${commit_limit}" --format=%H -- "${mirror_subdir}/"
  )

  log "No last-synced commit found within the last ${commit_limit} commit(s); listing all ${related_count}."
  return 0
}

declare -A target_modes=()
load_target_modes() {
  local entry mode rel_path

  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    rel_path="${entry#*$'\t'}"
    target_modes["${rel_path}"]="${mode}"
  done < <(git -C "${target_path}" ls-tree -r -z HEAD)
  return 0
}

# Lists mirrored files that are executable in the source but will not be in the target.
# Signed commits go through the GitHub API, whose file additions carry no mode.
collect_mode_fixes() {
  local entry mode tree_path rel_path

  while IFS= read -r -d '' entry; do
    mode="${entry%% *}"
    [[ "${mode}" == "100755" ]] || continue

    tree_path="${entry#*$'\t'}"
    rel_path="${tree_path#"${mirror_prefix}"}"
    if [[ "${target_modes[${rel_path}]-}" != "100755" ]]; then
      printf -- '%s\n' "${rel_path}"
    fi
  done < <(git -C "${source_path}" ls-tree -r -z "${head_sha}" -- "${mirror_subdir}/")
  return 0
}

render_mode_fix_notice() {
  local paths="${1:?render_mode_fix_notice requires a newline-separated path list}"
  local rel_path quoted_paths=""

  while IFS= read -r rel_path; do
    quoted_paths+=" '${rel_path}'"
  done <<< "${paths}"

  printf -- '%s\n' "The GitHub API cannot set file modes. Restore them before merging:"
  printf -- '\n%s\n' '```sh'
  printf -- '%s\n' "chmod u+x${quoted_paths}"
  printf -- '%s\n' '```'
  return 0
}

related_commits="$(collect_related_commits)"

load_target_modes
mode_fixes="$(collect_mode_fixes)"

body="Automated sync from ${repository}@${head_sha}."
if [[ -n "${related_commits}" ]]; then
  body+=$'\n\nRelated commits:\n'"${related_commits}"
fi
if [[ -n "${mode_fixes}" ]]; then
  body+=$'\n\n'"$(render_mode_fix_notice "${mode_fixes}")"
  log "⚠️ $(printf -- '%s\n' "${mode_fixes}" | wc -l | tr -d ' ') file(s) need their executable bit restored after merge."
fi

printf -- '%s\n' "${body}" > "${output_file}"
log "Wrote pull request body to '${output_file}'."
