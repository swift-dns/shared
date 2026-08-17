#!/usr/bin/env bash

set -Eeuo pipefail
shopt -s failglob
IFS=$'\n\t'

log() { printf -- "** %s\n" "$*" >&2; }
error() { printf -- "** ERROR: %s\n" "$*" >&2; }
fatal() { error "$@"; exit 1; }

readonly token="${GH_TOKEN:?GH_TOKEN must be a token allowed to write pull requests to REPOSITORY}"
readonly repository="${REPOSITORY:?REPOSITORY must be the owner/name of the target repository, e.g. 'swift-dns/swift-dns'}"
readonly head_branch="${HEAD_BRANCH:?HEAD_BRANCH must be the branch holding the synced files, e.g. 'sync-files'}"
readonly base_branch="${BASE_BRANCH:?BASE_BRANCH must be the branch the pull request targets, e.g. 'main'}"
readonly has_changes="${HAS_CHANGES:?HAS_CHANGES must be 'true' or 'false', as reported by commit-signed.sh}"
readonly title="${TITLE:?TITLE must be the pull request title}"
readonly body_file="${BODY_FILE:?BODY_FILE must be the file path holding the pull request body}"
readonly api_url="${GITHUB_API_URL:-https://api.github.com}"

if [[ ! "${repository}" =~ ^[^/]+/[^/]+$ ]]; then
  fatal "REPOSITORY is not in 'owner/name' form: '${repository}'"
fi
if [[ "${has_changes}" != "true" && "${has_changes}" != "false" ]]; then
  fatal "HAS_CHANGES is not 'true' or 'false': '${has_changes}'"
fi
[[ -f "${body_file}" ]] || fatal "BODY_FILE does not exist: '${body_file}'"

readonly repository_owner="${repository%%/*}"

workspace="$(mktemp -d)" || fatal "Failed to create a temporary workspace directory"
readonly workspace
trap 'rm -rf "${workspace}"' EXIT

readonly payload_file="${workspace}/payload.json"
readonly response_file="${workspace}/response.json"

github_api() {
  local method="${1:?github_api requires an HTTP method}"
  local url="${2:?github_api requires a URL}"
  local request_body_file="${3?github_api requires a request body file path, empty for none}"
  local response_body_file="${4:?github_api requires a response body file path}"

  local -a curl_args=(
    --silent
    --show-error
    --request "${method}"
    --header "Authorization: Bearer ${token}"
    --header "Accept: application/vnd.github+json"
    --header "X-GitHub-Api-Version: 2022-11-28"
    --output "${response_body_file}"
    --write-out '%{http_code}'
  )

  if [[ -n "${request_body_file}" ]]; then
    if [[ ! -f "${request_body_file}" ]]; then
      fatal "github_api request body file does not exist: '${request_body_file}'"
    fi
    curl_args+=(
      --header "Content-Type: application/json"
      --data-binary "@${request_body_file}"
    )
  fi

  : > "${response_body_file}"
  curl "${curl_args[@]}" "${url}" || error "Request failed: ${method} ${url}"
  return 0
}

api_failure_details() {
  local status="${1:?api_failure_details requires an HTTP status}"
  local response_body_file="${2:?api_failure_details requires a response body file path}"

  printf -- 'HTTP %s\n%s' "${status}" "$(cat "${response_body_file}")"
  return 0
}

# Lists the pull requests from HEAD_BRANCH into 'response_file', newest first.
fetch_pull_requests() {
  local query="state=all&head=${repository_owner}:${head_branch}&base=${base_branch}"
  query+="&sort=created&direction=desc&per_page=100"
  local url="${api_url}/repos/${repository}/pulls?${query}"
  local status
  status="$(github_api GET "${url}" "" "${response_file}")"

  if [[ "${status}" != "200" ]]; then
    fatal "Failed to list pull requests of '${repository}':" \
      "$(api_failure_details "${status}" "${response_file}")"
  fi
  return 0
}

delete_head_branch() {
  local url="${api_url}/repos/${repository}/git/refs/heads/${head_branch}"
  local status
  status="$(github_api DELETE "${url}" "" "${response_file}")"

  if [[ "${status}" == "204" ]]; then
    log "Deleted stale branch '${head_branch}', closing any pull request from it."
    return 0
  fi
  if [[ "${status}" != "404" && "${status}" != "422" ]]; then
    fatal "Failed to delete branch '${head_branch}' of '${repository}':" \
      "$(api_failure_details "${status}" "${response_file}")"
  fi

  log "Branch '${head_branch}' does not exist; nothing to clean up."
  return 0
}

create_pull_request() {
  local url="${api_url}/repos/${repository}/pulls"
  local status

  jq --null-input \
    --arg title "${title}" \
    --arg head "${head_branch}" \
    --arg base "${base_branch}" \
    --rawfile body "${body_file}" \
    '{title: $title, head: $head, base: $base, body: $body}' > "${payload_file}"
  status="$(github_api POST "${url}" "${payload_file}" "${response_file}")"
  if [[ "${status}" != "201" ]]; then
    fatal "Failed to create a pull request on '${repository}':" \
      "$(api_failure_details "${status}" "${response_file}")"
  fi

  log "✅ Opened pull request $(jq --raw-output '.html_url' "${response_file}")"
  return 0
}

update_pull_request() {
  local pull_request_number="${1:?update_pull_request requires a pull request number}"
  local url="${api_url}/repos/${repository}/pulls/${pull_request_number}"
  local status

  jq --null-input --arg title "${title}" --rawfile body "${body_file}" \
    '{title: $title, body: $body, state: "open"}' > "${payload_file}"
  status="$(github_api PATCH "${url}" "${payload_file}" "${response_file}")"
  if [[ "${status}" != "200" ]]; then
    fatal "Failed to update pull request #${pull_request_number}:" \
      "$(api_failure_details "${status}" "${response_file}")"
  fi
  if [[ "$(jq --raw-output '.state' "${response_file}")" != "open" ]]; then
    fatal "Pull request #${pull_request_number} of '${repository}' is not open after the update;" \
      "$(api_failure_details "${status}" "${response_file}")"
  fi

  log "✅ Updated pull request $(jq --raw-output '.html_url' "${response_file}")"
  return 0
}

if [[ "${has_changes}" == "false" ]]; then
  delete_head_branch
  exit 0
fi

fetch_pull_requests
existing_pull_request="$(jq --raw-output '
  ((first(.[] | select(.state == "open")) // first(.[] | select(.merged_at == null))) | .number)
  // empty
' "${response_file}")"
readonly existing_pull_request

if [[ -n "${existing_pull_request}" ]]; then
  update_pull_request "${existing_pull_request}"
else
  create_pull_request
fi
