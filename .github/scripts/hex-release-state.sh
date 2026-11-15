#!/usr/bin/env bash
# Prints the Hex state of one tama_dex release as GitHub step outputs:
#
#   package=live|approved|staged|missing
#   docs=live|approved|staged|missing
#   approval_url=<the staged release page, when anything is staged>
#
# Hex stages releases and docs published with an API key until an owner
# approves them. A staged release is not served by the releases endpoint,
# so its state is read from the staged endpoints, which need HEX_API_KEY.
#
# - live: the public release endpoint serves it.
# - approved: approved, but not served yet. Don't upload it again.
# - staged: waiting for an owner's approval. Don't upload it again.
# - missing: never uploaded, or its staged upload was rejected or expired.
#
# Any other answer stops with an error rather than risk a second upload.
#
# Usage: hex-release-state.sh VERSION
set -euo pipefail

package_name="tama_dex"
version="${1:?usage: hex-release-state.sh VERSION}"
api="${HEX_API_URL:-https://hex.pm/api}"
release_url="${api}/packages/${package_name}/releases/${version}"
body="$(mktemp)"
trap 'rm -f "${body}"' EXIT

# get URL [AUTH]: writes the response body to $body and prints the status.
get() {
  local args=(--silent --show-error --output "${body}" --write-out '%{http_code}')
  if [[ -n "${2:-}" ]]; then
    args+=(--header "authorization: ${2}")
  fi
  curl "${args[@]}" "$1"
}

# staged URL: approved, staged or missing, from a staged-release endpoint.
# It runs in a command substitution, where errexit doesn't apply, so every
# failure exits explicitly.
staged() {
  if [[ -z "${HEX_API_KEY:-}" ]]; then
    echo "::error::HEX_API_KEY is needed to read staged Hex releases" >&2
    exit 1
  fi

  local status state
  status="$(get "$1" "${HEX_API_KEY}")" || exit 1

  case "${status}" in
    200)
      if ! state="$(jq -er '.status | strings' "${body}")"; then
        echo "::error::Hex answered $1 without a readable status" >&2
        exit 1
      fi

      case "${state}" in
        staged | approved) echo "${state}" ;;
        # Nothing is pending, so it can be uploaded again.
        rejected | expired) echo missing ;;
        *)
          echo "::error::Hex answered $1 with an unknown status" >&2
          exit 1
          ;;
      esac
      ;;
    404) echo missing ;;
    *)
      echo "::error::Hex answered ${status} for $1" >&2
      exit 1
      ;;
  esac
}

status="$(get "${release_url}")"

case "${status}" in
  200)
    package="live"
    has_docs="$(jq -r '.has_docs == true' "${body}")"

    if [[ "${has_docs}" == "true" ]]; then
      docs="live"
    else
      docs="$(staged "${release_url}/docs/staged")"
    fi
    ;;
  404)
    package="$(staged "${release_url}/staged")"
    docs="$(staged "${release_url}/docs/staged")"
    ;;
  *)
    echo "::error::Hex answered ${status} when asked for ${package_name} ${version}" >&2
    exit 1
    ;;
esac

# staged() runs in a subshell, so the approval page is read here.
approval_url=""

if [[ "${package}" == "staged" || "${docs}" == "staged" ]]; then
  for path in staged docs/staged; do
    status="$(get "${release_url}/${path}" "${HEX_API_KEY}")"
    [[ "${status}" == "200" ]] || continue
    state="$(jq -r '.status' "${body}")"

    if [[ "${state}" == "staged" ]]; then
      approval_url="$(jq -r '.html_url // empty' "${body}")"
      break
    fi
  done
fi

echo "package=${package}"
echo "docs=${docs}"
echo "approval_url=${approval_url:-https://hex.pm/dashboard}"
