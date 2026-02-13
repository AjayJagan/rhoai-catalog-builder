#!/bin/bash
# Script to verify if a specific commit exists in a catalog's bundles

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${RESET} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${RESET} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${RESET} $*"
}

log_section() {
    echo -e "\n${CYAN}${BOLD}==> $*${RESET}"
}

# Usage
usage() {
    cat <<EOF
Usage: $0 --rhoai-version <version> --search <commit-sha> --catalog <catalog-image>

Search for a specific commit in bundles within an OLM catalog.

Required flags:
  --rhoai-version <version>    RHOAI version to search (e.g., v3.3, 3.3, rhoai-3.3)
  --search <commit-sha>        Git commit SHA to search for (full or short)
  --catalog <catalog-image>    Catalog image to inspect (e.g., quay.io/user/catalog:tag)

Optional flags:
  --image-builder <cmd>        Container tool (default: podman)
  --help                       Show this help message

Examples:
  # Search for a commit in v3.3 bundles
  $0 --rhoai-version v3.3 \\
     --search 76f52cabd2947851a82237fd42446d74f97c15a8 \\
     --catalog quay.io/ajaganat/opendatahub-operator-catalog:rhoai-2.25-rhoai-3.3-hybrid

  # Search with short commit SHA
  $0 --rhoai-version 3.3 \\
     --search 76f52ca \\
     --catalog quay.io/ajaganat/catalog:latest

EOF
    exit 0
}

# Parse arguments
RHOAI_VERSION=""
SEARCH_COMMIT=""
CATALOG_IMG=""
IMAGE_BUILDER="podman"

while [[ $# -gt 0 ]]; do
    case $1 in
        --rhoai-version)
            RHOAI_VERSION="$2"
            shift 2
            ;;
        --search)
            SEARCH_COMMIT="$2"
            shift 2
            ;;
        --catalog)
            CATALOG_IMG="$2"
            shift 2
            ;;
        --image-builder)
            IMAGE_BUILDER="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$RHOAI_VERSION" ]]; then
    log_error "Missing required flag: --rhoai-version"
    usage
fi

if [[ -z "$SEARCH_COMMIT" ]]; then
    log_error "Missing required flag: --search"
    usage
fi

if [[ -z "$CATALOG_IMG" ]]; then
    log_error "Missing required flag: --catalog"
    usage
fi

# Normalize version (remove 'v' prefix, 'rhoai-' prefix)
NORMALIZED_VERSION="${RHOAI_VERSION#v}"
NORMALIZED_VERSION="${NORMALIZED_VERSION#rhoai-}"

log_section "Searching for commit in catalog"
log_info "Catalog: $CATALOG_IMG"
log_info "Version: $RHOAI_VERSION (normalized: $NORMALIZED_VERSION)"
log_info "Commit: $SEARCH_COMMIT"

# Check prerequisites
for cmd in $IMAGE_BUILDER jq opm; do
    if ! command -v $cmd &> /dev/null; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

# Create temp directory
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

log_section "Extracting bundles from catalog"

# Render catalog to get all bundles
if ! opm render "$CATALOG_IMG" > "$TEMP_DIR/catalog.json" 2>/dev/null; then
    log_error "Failed to render catalog: $CATALOG_IMG"
    exit 1
fi

# Extract bundle images that match the version
log_info "Searching for bundles matching version pattern: $NORMALIZED_VERSION"

# Find bundles with names matching the version (e.g., rhods-operator.3.3.0)
matching_bundles=$(jq -r --arg version "$NORMALIZED_VERSION" '
    select(.schema == "olm.bundle") |
    select(.name | test("\\." + $version + "[.0-9]*$")) |
    .image
' "$TEMP_DIR/catalog.json")

if [[ -z "$matching_bundles" ]]; then
    log_warn "No bundles found matching version: $NORMALIZED_VERSION"

    # Show all available bundles
    log_info "Available bundles in catalog:"
    jq -r 'select(.schema == "olm.bundle") | "  - \(.name) (\(.image))"' "$TEMP_DIR/catalog.json"
    exit 1
fi

# Count matching bundles
bundle_count=$(echo "$matching_bundles" | wc -l | tr -d ' ')
log_success "Found $bundle_count bundle(s) matching version $NORMALIZED_VERSION"

# Search each bundle for the commit
FOUND=false
FOUND_IN_BUNDLE=""
FOUND_OPERATOR_IMAGE=""
FOUND_FULL_COMMIT=""

while IFS= read -r bundle_img; do
    [[ -z "$bundle_img" ]] && continue

    log_section "Checking bundle: $bundle_img"

    # Extract bundle name
    bundle_name=$(jq -r --arg img "$bundle_img" '
        select(.schema == "olm.bundle") |
        select(.image == $img) |
        .name
    ' "$TEMP_DIR/catalog.json")

    log_info "Bundle name: $bundle_name"

    # Extract bundle manifests
    bundle_dir="$TEMP_DIR/bundle-$(echo "$bundle_img" | md5sum | cut -d' ' -f1)"
    mkdir -p "$bundle_dir"

    container_id=$($IMAGE_BUILDER create --platform linux/amd64 "$bundle_img" 2>/dev/null || true)

    if [[ -z "$container_id" ]]; then
        log_warn "Failed to create container from bundle image"
        continue
    fi

    if ! $IMAGE_BUILDER cp "$container_id:/manifests" "$bundle_dir/manifests" 2>/dev/null; then
        log_warn "Failed to extract manifests from bundle"
        $IMAGE_BUILDER rm "$container_id" >/dev/null 2>&1 || true
        continue
    fi

    $IMAGE_BUILDER rm "$container_id" >/dev/null 2>&1 || true

    # Find CSV file
    csv_file=$(find "$bundle_dir/manifests" -name '*clusterserviceversion.yaml' -o -name '*clusterserviceversion.yml' 2>/dev/null | head -1)

    if [[ -z "$csv_file" ]]; then
        log_warn "No CSV found in bundle"
        continue
    fi

    # Extract operator image from CSV
    operator_image=$(yq '.spec.install.spec.deployments[0].spec.template.spec.containers[0].image' "$csv_file" 2>/dev/null || true)

    if [[ -z "$operator_image" ]]; then
        log_warn "No operator image found in CSV"
        continue
    fi

    log_info "Operator image: $operator_image"

    # Check operator image labels for commit
    log_info "Checking operator image for commit..."

    operator_labels=$($IMAGE_BUILDER inspect "$operator_image" 2>/dev/null | jq -r '.[0].Labels' || echo '{}')

    if [[ "$operator_labels" == "{}" ]]; then
        log_warn "Failed to inspect operator image or no labels found"
        continue
    fi

    # Extract commit from labels
    commit=$(echo "$operator_labels" | jq -r '.["org.opencontainers.image.revision"] // empty' 2>/dev/null || true)

    if [[ -z "$commit" ]]; then
        log_warn "No git commit found in operator image labels"
        continue
    fi

    log_info "Found commit in operator image: $commit"

    # Check if commit matches (support both full and short SHA)
    if [[ "$commit" == "$SEARCH_COMMIT"* ]] || [[ "$SEARCH_COMMIT" == "$commit"* ]]; then
        FOUND=true
        FOUND_IN_BUNDLE="$bundle_name ($bundle_img)"
        FOUND_OPERATOR_IMAGE="$operator_image"
        FOUND_FULL_COMMIT="$commit"
        break
    else
        log_warn "Commit does not match. Expected: $SEARCH_COMMIT, Found: $commit"
    fi

done <<< "$matching_bundles"

# Print results
log_section "Results"

if [[ "$FOUND" == true ]]; then
    log_success "✓ Commit FOUND!"
    echo ""
    echo "  Bundle:         $FOUND_IN_BUNDLE"
    echo "  Operator Image: $FOUND_OPERATOR_IMAGE"
    echo "  Git Commit:     $FOUND_FULL_COMMIT"
    echo ""
    exit 0
else
    log_error "✗ Commit NOT FOUND"
    echo ""
    echo "  Searched for: $SEARCH_COMMIT"
    echo "  In version:   $NORMALIZED_VERSION bundles"
    echo "  Catalog:      $CATALOG_IMG"
    echo ""
    exit 1
fi
