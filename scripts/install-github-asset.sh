#!/bin/bash
# This script downloads a binary from GitHub download and installs it into an Upsun app container.
# It handles extracting the file and caching the result.
#
# In the build hook (in the Upsun YAML app configuration), add the following:
#   curl -fsS https://raw.githubusercontent.com/upsun/config-assets/main/scripts/install-github-asset.sh | bash -s -- "<org/repo>" "[<release_version>]" "[<asset_name>]"
#
# Examples:
#   curl -fsS https://raw.githubusercontent.com/upsun/config-assets/main/scripts/install-github-asset.sh | bash -s -- jgm/pandoc
#   curl -fsS https://raw.githubusercontent.com/upsun/config-assets/main/scripts/install-github-asset.sh | bash -s -- mikefarah/yq 4.45.1
#   curl -fsS https://raw.githubusercontent.com/upsun/config-assets/main/scripts/install-github-asset.sh | bash -s -- dunglas/frankenphp 1.5.0 frankenphp-linux-x86_64-gnu
#
# Contributors:
#  - Florent HUCK <florent.huck@platform.sh>

RED='\033[0;31m'
RED_BOLD='\033[01;31m'
GREEN='\033[0;32m'
GREEN_BOLD='\033[01;32m'
NC='\033[0m'

# Security constants
MAX_FILE_SIZE=1073741824  # 1GB limit
CURL_TIMEOUT=300          # 5 minutes timeout

# Global variable to cache releases data
RELEASES_DATA=""

fetch_releases_data() {
  if [ -n "${RELEASES_DATA}" ]; then
    return 0  # Already cached
  fi

  local api_response
  api_response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -L \
    --max-time 30 \
    ${AUTH_HEADER:+-H "$AUTH_HEADER"} \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${GITHUB_ORG}/${TOOL_NAME}/releases?per_page=5")

  if [ $? -ne 0 ]; then
    error_exit "Failed to fetch releases from GitHub API"
  fi

  local http_status=$(echo "${api_response}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
  RELEASES_DATA=$(echo "${api_response}" | sed -e 's/HTTPSTATUS\:.*//g')

  if [ "${http_status}" -ge 400 ]; then
    error_exit "GitHub API request failed with status ${http_status}"
  fi

  if ! echo "${RELEASES_DATA}" | jq empty >/dev/null 2>&1; then
    error_exit "Invalid JSON response from GitHub API"
  fi
}

error_exit() {
  printf "❌ ${RED_BOLD}$1${NC}\n"
  exit 1
}

validate_inputs() {
  # Validate GitHub org/repo format
  if ! echo "${GITHUB_REPO}" | grep -qE '^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$'; then
    printf "${RED_BOLD}Invalid repository format: ${GITHUB_REPO}${NC}\\n"
    printf "${RED}Expected format: org/repo (alphanumeric, dots, underscores, hyphens only)${NC}\\n"
    exit 1
  fi

  # Validate version format if specified
  if [ -n "${TOOL_VERSION}" ] && ! echo "${TOOL_VERSION}" | grep -qE '^[a-zA-Z0-9._-]+$'; then
    printf "${RED_BOLD}Invalid version format: ${TOOL_VERSION}${NC}\\n"
    printf "${RED}Version must contain only alphanumeric characters, dots, underscores, and hyphens${NC}\\n"
    exit 1
  fi

  # Validate asset name format if specified
  if [ -n "${ASSET_NAME_PARAM}" ] && ! echo "${ASSET_NAME_PARAM}" | grep -qE '^[a-zA-Z0-9._-]+$'; then
    printf "${RED_BOLD}Invalid asset name format: ${ASSET_NAME_PARAM}${NC}\\n"
    printf "${RED}Asset name must contain only alphanumeric characters, dots, underscores, and hyphens${NC}\\n"
    exit 1
  fi

  # Extract and validate individual components
  GITHUB_ORG=$(echo "${GITHUB_REPO}" | cut -d'/' -f1)
  TOOL_NAME=$(echo "${GITHUB_REPO}" | cut -d'/' -f2)

  # Additional length checks to prevent excessively long inputs
  if [ ${#GITHUB_ORG} -gt 50 ] || [ ${#TOOL_NAME} -gt 50 ]; then
    printf "${RED_BOLD}Organization or repository name too long (max 50 characters each)${NC}\\n"
    exit 1
  fi

  if [ -n "${ASSET_NAME_PARAM}" ] && [ ${#ASSET_NAME_PARAM} -gt 100 ]; then
    printf "${RED_BOLD}Asset name too long (max 100 characters)${NC}\\n"
    exit 1
  fi
}

sanitize_filename() {
  # Remove path traversal attempts and dangerous characters from filename
  local filename="$1"
  # Remove path components
  filename=$(basename "${filename}")
  # Remove dangerous characters
  filename=$(echo "${filename}" | sed 's/[^a-zA-Z0-9._-]//g')
  echo "${filename}"
}

validate_archive_paths() {
  local extract_dir="$1"
  while IFS= read -r -d '' file; do
    local rel_path="${file#"${extract_dir}"/}"
    if [[ "${rel_path}" == *"../"* ]] || [[ "${rel_path:0:1}" == "/" ]]; then
      error_exit "Security violation: Archive contains dangerous path: ${rel_path}"
    fi
  done < <(find "${extract_dir}" -type f -print0)
}

get_asset_checksum() {
  local asset_name="$1"
  fetch_releases_data

  local checksums_asset=$(echo "${RELEASES_DATA}" | jq -r --arg TOOL_VERSION "${TOOL_VERSION}" '
    .[] | select(.tag_name==$TOOL_VERSION) | .assets | map(select(
      (.name | test("checksum|sha256|sha1|md5"; "i")) or (.name | test("sum"; "i"))
    )) | .[0]')

  if [ "${checksums_asset}" = "null" ] || [ -z "${checksums_asset}" ]; then
    return 1
  fi

  local checksums_url=$(echo "${checksums_asset}" | jq -r '.browser_download_url')
  local checksums_file="/tmp/checksums"

  curl --silent -L "${checksums_url}" ${AUTH_HEADER:+-H "${AUTH_HEADER}"} -o "${checksums_file}" || return 1

  local checksum=""
  if grep -q "${asset_name}" "${checksums_file}"; then
    checksum=$(grep "${asset_name}" "${checksums_file}" | awk '{print $1}')
  elif grep -q "$(basename "${asset_name}")" "${checksums_file}"; then
    checksum=$(grep "$(basename "${asset_name}")" "${checksums_file}" | awk '{print $1}')
  fi

  rm -f "${checksums_file}"
  [ -n "${checksum}" ] && echo "${checksum}"
}

verify_checksum() {
  local file_path="$1"
  local expected_checksum="$2"

  if [ -z "${expected_checksum}" ]; then
    echo "⚠️  No checksum available for verification"
    return 0
  fi

  # Determine hash type by checksum length
  local hash_cmd=""
  case ${#expected_checksum} in
    32)
      hash_cmd="md5sum"
      ;;
    40)
      hash_cmd="sha1sum"
      ;;
    64)
      hash_cmd="sha256sum"
      ;;
    *)
      echo "⚠️  Unknown checksum format (length: ${#expected_checksum})"
      return 0
      ;;
  esac

  # Check if hash command is available
  if ! command -v "${hash_cmd}" >/dev/null 2>&1; then
    echo "⚠️  ${hash_cmd} not available for verification"
    return 0
  fi

  local actual_checksum=$(${hash_cmd} "${file_path}" | awk '{print $1}')

  if [ "${actual_checksum}" = "${expected_checksum}" ]; then
    printf "✅ ${GREEN}Checksum verification passed${NC}\\n"
    return 0
  else
    printf "❌ ${RED_BOLD}Checksum verification failed!${NC}\\n"
    printf "Expected: ${expected_checksum}\\n"
    printf "Actual:   ${actual_checksum}\\n"
    return 1
  fi
}

# Set GITHUB_TOKEN to allow accessing private repositories or to increase GitHub's rate limit.
if [ -n "${GITHUB_TOKEN}" ]; then
  AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
else
  AUTH_HEADER=""
fi

run() {
  # Run the process.
  cd "$PLATFORM_CACHE_DIR" || exit 1

  if [ -z "${ASSET_NAME_PARAM}" ] && [ ! -f "${PLATFORM_CACHE_DIR}/${TOOL_NAME}/${TOOL_VERSION}/${TOOL_NAME}" ] ||
     [ -n "${ASSET_NAME_PARAM}" ] && [ ! -f "${PLATFORM_CACHE_DIR}/${TOOL_NAME}/${TOOL_VERSION}/${ASSET_NAME_PARAM}/${TOOL_NAME}" ]; then
    ensure_source
    download_binary
    move_binary
  else
    echo "Found ${TOOL_NAME} ${TOOL_VERSION} in cache"
  fi

  copy_lib "${TOOL_NAME}" "${TOOL_VERSION}"

  printf "✅ ${GREEN_BOLD}${TOOL_NAME} installation successful${NC}\n"

  printf "${GREEN}To use it, run: ${NC}${GREEN_BOLD}${TOOL_NAME}${NC}\n"
}

ensure_source() {
  echo "Ensuring cache directory exists..."
  mkdir -p "$PLATFORM_CACHE_DIR/${TOOL_NAME}/${TOOL_VERSION}"
  cd "$PLATFORM_CACHE_DIR/${TOOL_NAME}/${TOOL_VERSION}" || exit 1
}

download_binary() {
  echo "Downloading ${TOOL_NAME} binary (version ${TOOL_VERSION})..."

  TMP_DEST="/tmp/${TOOL_NAME}"
  mkdir -p "${TMP_DEST}"

  get_asset_id

  # Fetch checksum for verification
  local expected_checksum=""
  if expected_checksum=$(get_asset_checksum "${ASSET_NAME}"); then
    echo "Found checksum: ${expected_checksum}"
  else
    echo "⚠️  No checksum found for ${ASSET_NAME}"
  fi

  # Download asset with error handling and limits
  if ! curl --progress-bar -L \
    --max-filesize "${MAX_FILE_SIZE}" \
    --max-time "${CURL_TIMEOUT}" \
    -H "Accept: application/octet-stream" "https://api.github.com/repos/${GITHUB_ORG}/${TOOL_NAME}/releases/assets/${ASSET_ID}" \
    ${AUTH_HEADER:+-H "${AUTH_HEADER}"} \
    -o "${TMP_DEST}/${TOOL_NAME}-asset"; then
    echo "❌ Failed to download ${TOOL_NAME} binary (curl exit code: $?)"
    rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
    exit 1
  fi

  # Check if the download was successful
  if [[ ! -f "${TMP_DEST}/${TOOL_NAME}-asset" ]]; then
    echo "❌ Failed to download ${TOOL_NAME} binary - file does not exist"
    exit 1
  fi

  # Check file size
  local file_size=$(wc -c < "${TMP_DEST}/${TOOL_NAME}-asset")
  if [ "${file_size}" -eq 0 ]; then
    echo "❌ Downloaded file is empty"
    rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
    exit 1
  fi

  # Verify checksum if available
  if [ -n "${expected_checksum}" ]; then
    if ! verify_checksum "${TMP_DEST}/${TOOL_NAME}-asset" "${expected_checksum}"; then
      rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
      exit 1
    fi
  fi

  # Check the file type of the downloaded asset
  FILE_TYPE=$(file -b --mime-type "${TMP_DEST}/${TOOL_NAME}-asset")
  echo "Downloaded file type: ${FILE_TYPE}"

  # Validate file type matches expected content type
  case "${ASSET_CONTENT_TYPE}" in
  application/zip)
    if [[ "${FILE_TYPE}" != "application/zip" ]]; then
      rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
      error_exit "File type mismatch: expected ${ASSET_CONTENT_TYPE}, got ${FILE_TYPE}"
    fi
    ;;
  application/gzip | application/x-gzip | application/x-tar | application/x-gtar)
    if [[ "${FILE_TYPE}" != "application/gzip" && "${FILE_TYPE}" != "application/x-gzip" && "${FILE_TYPE}" != "application/x-tar" ]]; then
      rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
      error_exit "File type mismatch: expected gzip/tar archive, got ${FILE_TYPE}"
    fi
    ;;
  esac

  # Extract accordingly
  case "${ASSET_CONTENT_TYPE}" in
  application/zip)
    if ! unzip -q "${TMP_DEST}/${TOOL_NAME}-asset" -d "${TMP_DEST}/"; then
      echo "❌ Failed to extract zip archive"
      rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
      exit 1
    fi
    rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
    # Validate extracted paths
    validate_archive_paths "${TMP_DEST}"
    ;;
  application/gzip | application/x-gzip | application/x-tar | application/x-gtar)
    if ! tar --anchored --exclude=../* -xzf "${TMP_DEST}/${TOOL_NAME}-asset" -C "${TMP_DEST}/"; then
      echo "❌ Failed to extract tar.gz archive"
      rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
      exit 1
    fi
    rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
    # Validate extracted paths
    validate_archive_paths "${TMP_DEST}"
    ;;
  *)
    echo "No extraction needed for ${ASSET_CONTENT_TYPE} file"
    # Sanitize the filename for the final binary
    local sanitized_name=$(sanitize_filename "${TOOL_NAME}")
    if ! mv "${TMP_DEST}/${TOOL_NAME}-asset" "/tmp/${TOOL_NAME}/${sanitized_name}"; then
      echo "❌ Failed to move binary file"
      rm -f "${TMP_DEST}/${TOOL_NAME}-asset"
      exit 1
    fi
    ;;
  esac

  echo "Download complete"
}

move_binary() {
  echo "Caching ${TOOL_NAME} binary..."

  # Search for binary in the archive tree
  FOUND=$(find "${TMP_DEST}" -type f -name "${TOOL_NAME}" | head -n1)
  if [ -z "${FOUND}" ]; then
    printf >&2 "❌ ${RED_BOLD}Can't find ${TOOL_NAME} in the subtree of /tmp/${NC}\n\n"
    exit 1
  fi

  echo "Found binary: $(basename "$FOUND")"

  # Get the directory where the binary is located
  BINARY_DIR=$(dirname "$FOUND")

  # copy all binaries in the BINARY_DIR in cache folder
  if [ -z "${ASSET_NAME_PARAM}" ]; then
    DEST_DIR="${PLATFORM_CACHE_DIR}/${TOOL_NAME}/${TOOL_VERSION}"
  else
    DEST_DIR="${PLATFORM_CACHE_DIR}/${TOOL_NAME}/${TOOL_VERSION}/${ASSET_NAME_PARAM}"
    mkdir -p "$DEST_DIR"
  fi

  if [ "${BINARY_DIR}" != "${DEST_DIR}" ]; then
    cp -r "${BINARY_DIR}/." "${DEST_DIR}/"
    rm -rf "${BINARY_DIR}"
  fi

  echo "Cache updated"
}

copy_lib() {
  echo "Copying ${TOOL_NAME} to the PATH..."

  # Ensure destination directory exists
  if ! mkdir -p "${PLATFORM_APP_DIR}/.global/bin"; then
    printf "❌ ${RED_BOLD}Failed to create destination directory: ${PLATFORM_APP_DIR}/.global/bin${NC}\n"
    exit 1
  fi

  # Determine source directory based on asset name parameter
  local source_dir
  if [ -z "${ASSET_NAME_PARAM}" ]; then
    source_dir="${PLATFORM_CACHE_DIR}/${TOOL_NAME}/${TOOL_VERSION}"
  else
    source_dir="${PLATFORM_CACHE_DIR}/${TOOL_NAME}/${TOOL_VERSION}/${ASSET_NAME_PARAM}"
  fi

  # Verify source directory exists
  if [ ! -d "${source_dir}" ]; then
    printf "❌ ${RED_BOLD}Source directory does not exist: ${source_dir}${NC}\n"
    exit 1
  fi

  # Copy files and check for errors
  local files_copied=0
  while IFS= read -r -d '' file; do
    if ! cp -f "${file}" "${PLATFORM_APP_DIR}/.global/bin"; then
      printf "❌ ${RED_BOLD}Failed to copy ${file} to ${PLATFORM_APP_DIR}/.global/bin${NC}\n"
      exit 1
    fi
    files_copied=$((files_copied + 1))
  done < <(find "${source_dir}/" -maxdepth 1 \( -type f -o -type l \) -print0)

  if [ "${files_copied}" -eq 0 ]; then
    printf "❌ ${RED_BOLD}No files found to copy in ${source_dir}${NC}\n"
    exit 1
  fi

  # Make binaries executable and check for errors
  while IFS= read -r -d '' file; do
    if ! chmod +x "${file}"; then
      printf "❌ ${RED_BOLD}Failed to make ${file} executable${NC}\n"
      exit 1
    fi
  done < <(find "${PLATFORM_APP_DIR}/.global/bin" -maxdepth 1 \( -type f -o -type l \) -print0)

}

get_asset_id() {
  fetch_releases_data

  if [ -z "${ASSET_NAME_PARAM}" ]; then
    echo >&2 "Auto-detecting linux/x86_64 asset..."
    ASSET=$(echo "${RELEASES_DATA}" | jq -r --arg TOOL_VERSION "${TOOL_VERSION}" '
      .[] | select(.tag_name==$TOOL_VERSION) | .assets | map(select(
        (.name | test("linux")) and (.name | test("x86|amd64")) and (.name | test("\\.(tgz|tar\\.gz|gz|zip|tar\\.bz2|tar\\.xz)$"))
      )) | .[0]')
  else
    echo >&2 "Searching for asset: ${ASSET_NAME_PARAM}"
    ASSET=$(echo "${RELEASES_DATA}" | jq -r --arg TOOL_VERSION "${TOOL_VERSION}" --arg BINARY_NAME "${ASSET_NAME_PARAM}" '
      .[] | select(.tag_name==$TOOL_VERSION) | .assets[] | select(.name==$BINARY_NAME)')
  fi

  if [ "${ASSET}" = "null" ] || [ -z "${ASSET}" ]; then
    error_exit "Can't find matching asset for ${TOOL_NAME} version ${TOOL_VERSION}"
  fi

  ASSET_ID=$(echo "${ASSET}" | jq -r '.id')
  ASSET_NAME=$(echo "${ASSET}" | jq -r '.name')
  ASSET_CONTENT_TYPE=$(echo "${ASSET}" | jq -r '.content_type')

  if [ -z "${ASSET_ID}" ] || [ "${ASSET_ID}" = "null" ]; then
    error_exit "Can't extract asset ID from API response"
  elif [ -z "${ASSET_NAME}" ] || [ "${ASSET_NAME}" = "null" ]; then
    error_exit "Can't extract asset name from API response"
  fi

  echo "Found asset: ${ASSET_NAME}"
}

ensure_environment() {
  # If not running in an Upsun build environment, do nothing.
  if [ -z "${PLATFORM_CACHE_DIR}" ]; then
    printf "${RED_BOLD}Not running in an Upsun build environment. Aborting ${TOOL_NAME} installation.${NC}\n"
    exit 1
  fi
}

get_repo_latest_version() {
  fetch_releases_data
  local response=$(echo "${RELEASES_DATA}" | jq -r '.[0].tag_name')
  [ "${response}" != "null" ] && [ -n "${response}" ] && TOOL_VERSION=${response}
}

check_version_exists() {
  fetch_releases_data
  VERSION_FOUND=$(echo "${RELEASES_DATA}" | jq -r --arg TOOL_VERSION "${TOOL_VERSION}" '.[] | select(.tag_name==$TOOL_VERSION) | .tag_name')
}

check_repository_auth() {
  # Make the API request and capture both body and HTTP status code
  response=$(curl --silent --write-out "HTTPSTATUS:%{http_code}" -L \
    -H "Accept: application/vnd.github+json" \
    ${AUTH_HEADER:+-H "${AUTH_HEADER}"} \
    "https://api.github.com/repos/${GITHUB_ORG}/${TOOL_NAME}")

  # Separate the response body and HTTP status
  body=$(echo "${response}" | sed -e 's/HTTPSTATUS\:.*//g')
  status=$(echo "${response}" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')

  # Extract the repository visibility
  is_private=$(echo "${body}" | jq -r '.private')

  # Inform the user whether the repo is public or private (can get a 404 if private)
  if [ "${is_private}" = "true" ]; then
    echo "🔒 This repository is private."
    if [ -z "${GITHUB_TOKEN}" ]; then
      echo "💡 Please export a valid GITHUB_TOKEN to access private repositories."
      exit 1
    fi
  fi

  # Handle 404 or other HTTP errors
  if [ "${status}" -eq 404 ]; then
    if [ -z "${GITHUB_TOKEN}" ]; then
      printf "❌ ${RED_BOLD}Repository not accessible (404).${NC}\n"
      printf "💡 ${RED_BOLD}It might be a private repository. Please set a valid GITHUB_TOKEN environment variable.${NC}\n\n"
    else
      printf "❌ ${RED_BOLD}Repository not found or inaccessible. Make sure the GITHUB_TOKEN has the correct permissions.${NC}\n\n"
    fi
    exit 1
  elif [ "${status}" -ge 400 ]; then
    printf "❌ ${RED_BOLD}GitHub API request failed with status ${status}.${NC}\n"
    printf "${body}\n\n"
    exit 1
  fi
}

# Get first parameter as the Github identifier: <org>/<repo>
if [ -z "${1}" ]; then
  printf "${RED_BOLD}GitHub asset installation error${NC}\n"
  printf "${RED}Please provide the GitHub organization and repository where to find the tool, as first parameter.${NC}\n"
  printf "${RED}Ex: curl https://raw.githubusercontent.com/upsun/config-assets/main/scripts/install-github-asset.sh | bash -s -- jgm/pandoc${NC}\n\n"
  exit 1
else
  printf "${GREEN_BOLD}Installing GitHub asset: $1${NC}\n"
  GITHUB_REPO="$1"
  # Set parameters for validation
  TOOL_VERSION="$2"
  ASSET_NAME_PARAM="$3"

  # Validate all inputs
  validate_inputs
fi


# check if we are on an Upsun
ensure_environment
check_repository_auth

# Handle version parameter
if [ -z "${TOOL_VERSION}" ]; then
  echo >&2 "Finding latest version..."
  get_repo_latest_version
  if [ -n "${TOOL_VERSION}" ]; then
    echo "Latest version: ${TOOL_VERSION}"
    # Validate the tool version from the API
    if ! echo "${TOOL_VERSION}" | grep -qE '^[a-zA-Z0-9._-]+$'; then
      printf "${RED_BOLD}Invalid version format from API: ${TOOL_VERSION}${NC}\n"
      exit 1
    fi
  fi
else
  check_version_exists
  if [ -z "${VERSION_FOUND}" ]; then
    echo "The version specified for ${GITHUB_ORG}/${TOOL_NAME} (${TOOL_VERSION}) was not found."
    echo "Please check available releases on https://github.com/${GITHUB_ORG}/${TOOL_NAME}/releases"
    exit 1
  else
    echo "Version specified for ${GITHUB_ORG}/${TOOL_NAME}: ${TOOL_VERSION}"
    TOOL_VERSION="${VERSION_FOUND}"
  fi
fi

if [ -z "${TOOL_VERSION}" ]; then
  printf "${RED_BOLD}Warning: No valid release version found for $1, aborting installation.${NC}\n\n"
  exit 1
fi

# Asset name parameter is handled in validate_inputs()

run
