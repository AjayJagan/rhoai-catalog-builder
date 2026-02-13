#!/bin/bash

set -euo pipefail

#######################################
# RHOAI Catalog Builder — Hybrid Bundle with RELATED_IMAGE Extraction
#
# Builds a custom OLM catalog for testing RHOAI operator upgrades.
# The primary mode extracts production bundle manifests (CSV + RELATED_IMAGEs)
# and swaps only the operator image with a custom-built one from a feature branch.
#
# How it works:
#   1. All --bundle args except the last are used as-is (production images)
#   2. The last --bundle is "hybridized":
#      - Production CSV + CRDs are extracted from the bundle image
#      - The operator image reference in the CSV is replaced with a custom one
#      - All RELATED_IMAGE env vars are preserved (production component images)
#      - A new hybrid bundle image is built and pushed
#   3. A file-based catalog (FBC) is built with the correct upgrade chain
#   4. The catalog is verified using opm render
#
# Prerequisites:
#   - podman (logged into push registry)
#   - git, jq, yq (v4+)
#   - opm (auto-downloaded if not found)
#   - Run from the opendatahub-operator repository root
#
# Examples:
#   # Upgrade test: 2.25 → 3.3 with custom operator from current branch
#   ./scripts/rhoai-catalog-builder.sh \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
#     --registry quay.io/ajaganat
#
#   # Specify which branch to build the operator from
#   ./scripts/rhoai-catalog-builder.sh \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
#     --registry quay.io/ajaganat \
#     --branch test-hwp-change
#
#   # Use a pre-built operator image (skip operator build)
#   ./scripts/rhoai-catalog-builder.sh \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
#     --registry quay.io/ajaganat \
#     --operator-image quay.io/ajaganat/rhods-operator:custom-rhoai-3.3
#
#   # Three-version upgrade chain
#   ./scripts/rhoai-catalog-builder.sh \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.2 \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
#     --registry quay.io/ajaganat \
#     --catalog-tag v2.25-3.2-3.3
#
#   # All pre-existing bundles, no hybrid (skip operator build entirely)
#   ./scripts/rhoai-catalog-builder.sh \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
#     --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
#     --registry quay.io/ajaganat \
#     --no-build
#######################################

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Global variables
declare -a BUNDLE_SPECS=()
REGISTRY=""
CATALOG_TAG=""
BRANCH=""
OPERATOR_IMAGE=""
NO_BUILD=false
IMAGE_BUILDER="podman"
DRY_RUN=false
ORIGINAL_BRANCH=""
STASHED_CHANGES=false
OPM_BIN=""
TMP_DIR=""
CLEANUP_DONE=false

# The final list of bundle images to include in the catalog (after hybrid build)
declare -a RESOLVED_BUNDLE_IMGS=()
# The custom operator image (built or provided)
CUSTOM_OPERATOR_IMG=""
# The hybrid bundle image that was built
HYBRID_BUNDLE_IMG=""

#######################################
# Logging
#######################################
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

#######################################
# Execute command (respects dry-run)
#######################################
execute() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*" >&2
    else
        log_info "Executing: $*"
        eval "$@"
    fi
}

#######################################
# Cleanup — restores git state, removes temp files
# Triggered via trap on EXIT (covers ERR, INT, TERM)
#######################################
cleanup() {
    if [[ "$CLEANUP_DONE" == true ]]; then
        return
    fi
    CLEANUP_DONE=true

    if [[ "$DRY_RUN" == true ]]; then
        return
    fi

    log_info "Cleaning up..."

    # Remove temp directory
    if [[ -n "$TMP_DIR" ]] && [[ -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi

    # Clean generated catalog directory
    rm -rf catalog 2>/dev/null || true

    # Return to original branch if we switched
    if [[ -n "$ORIGINAL_BRANCH" ]]; then
        local current_branch
        current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
        if [[ -n "$current_branch" ]] && [[ "$current_branch" != "$ORIGINAL_BRANCH" ]]; then
            log_info "Returning to original branch: $ORIGINAL_BRANCH"
            git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
        fi
    fi

    # Restore stashed changes
    if [[ "$STASHED_CHANGES" == true ]]; then
        log_info "Restoring stashed changes..."
        if git stash pop &>/dev/null; then
            log_success "Stashed changes restored"
        else
            log_warn "Could not restore stash automatically. Run: git stash pop"
        fi
    fi
}

trap cleanup EXIT

#######################################
# Usage
#######################################
usage() {
    cat << 'EOF'
Usage: rhoai-catalog-builder.sh [OPTIONS]

Builds a custom RHOAI catalog for testing operator upgrades.
Extracts production bundle manifests (CSV + RELATED_IMAGEs) and swaps
only the operator image with a custom-built one from a feature branch.

Core behavior:
  - All --bundle args except the last are used as-is (production images)
  - The last --bundle is hybridized: production CSV + RELATED_IMAGEs are
    preserved, only the operator image is swapped with a custom one
  - Use --no-build to skip hybridization (all bundles used as-is)

Required:
  --bundle <image>        Bundle image to include (repeatable, order = upgrade chain)
  --registry <registry>   Push registry (e.g., quay.io/ajaganat)

Optional:
  --branch <name>         Branch to build custom operator from (default: current branch)
  --operator-image <img>  Pre-built operator image (skips operator build)
  --catalog-tag <tag>     Tag for catalog image (default: auto-generated)
  --no-build              Use all bundles as-is, no hybrid build
  --image-builder <cmd>   Container build tool (default: podman)
  --dry-run               Print commands without executing
  --help                  Show this help message

Examples:
  # Upgrade test: 2.25 → 3.3 with custom operator from current branch
  rhoai-catalog-builder.sh \
    --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
    --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
    --registry quay.io/ajaganat

  # Use a pre-built operator image
  rhoai-catalog-builder.sh \
    --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
    --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
    --registry quay.io/ajaganat \
    --operator-image quay.io/ajaganat/rhods-operator:custom

  # All pre-existing bundles (no hybrid)
  rhoai-catalog-builder.sh \
    --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
    --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
    --registry quay.io/ajaganat \
    --no-build
EOF
    exit 0
}

#######################################
# Argument parsing
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --bundle)
                BUNDLE_SPECS+=("$2")
                shift 2
                ;;
            --registry)
                REGISTRY="$2"
                shift 2
                ;;
            --branch)
                BRANCH="$2"
                shift 2
                ;;
            --operator-image)
                OPERATOR_IMAGE="$2"
                shift 2
                ;;
            --catalog-tag)
                CATALOG_TAG="$2"
                shift 2
                ;;
            --no-build)
                NO_BUILD=true
                shift
                ;;
            --image-builder)
                IMAGE_BUILDER="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
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
}

#######################################
# Validate arguments
#######################################
validate_args() {
    if [[ ${#BUNDLE_SPECS[@]} -eq 0 ]]; then
        log_error "At least one --bundle is required"
        exit 1
    fi

    if [[ -z "$REGISTRY" ]]; then
        log_error "Missing required argument: --registry"
        exit 1
    fi

    # Remove trailing slash from registry
    REGISTRY="${REGISTRY%/}"

    # --operator-image and --no-build are mutually exclusive
    if [[ -n "$OPERATOR_IMAGE" ]] && [[ "$NO_BUILD" == true ]]; then
        log_error "--operator-image and --no-build are mutually exclusive"
        exit 1
    fi

    # Auto-generate catalog tag if not provided
    if [[ -z "$CATALOG_TAG" ]]; then
        local tags=()
        for img in "${BUNDLE_SPECS[@]}"; do
            # Extract tag from image reference (part after last colon)
            local tag="${img##*:}"
            tags+=("$tag")
        done
        if [[ "$NO_BUILD" == true ]]; then
            CATALOG_TAG=$(IFS='-'; echo "${tags[*]}")
        else
            CATALOG_TAG="$(IFS='-'; echo "${tags[*]}")-hybrid"
        fi
    fi

    log_info "Configuration:"
    log_info "  Bundles: ${BUNDLE_SPECS[*]}"
    log_info "  Registry: $REGISTRY"
    log_info "  Catalog Tag: $CATALOG_TAG"
    if [[ "$NO_BUILD" == true ]]; then
        log_info "  Mode: no-build (all bundles as-is)"
    elif [[ -n "$OPERATOR_IMAGE" ]]; then
        log_info "  Mode: hybrid with pre-built operator"
        log_info "  Operator Image: $OPERATOR_IMAGE"
    else
        log_info "  Mode: hybrid (build operator from branch)"
        log_info "  Branch: ${BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'current')}"
    fi
    log_info "  Image Builder: $IMAGE_BUILDER"
    log_info "  Dry Run: $DRY_RUN"
}

#######################################
# Check prerequisites
#######################################
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Required commands
    local required_commands=("$IMAGE_BUILDER" "git" "jq" "yq")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Required command not found: $cmd"
            exit 1
        fi
    done

    # Check we're in the repo root
    if [[ ! -f "Makefile" ]] || [[ ! -f "get_all_manifests.sh" ]]; then
        log_error "This script must be run from the opendatahub-operator repository root"
        exit 1
    fi

    # Save original branch
    ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    log_info "Current branch: $ORIGINAL_BRANCH"

    # Set default branch to current if not specified
    if [[ -z "$BRANCH" ]]; then
        BRANCH="$ORIGINAL_BRANCH"
    fi

    # Create temp directory
    TMP_DIR=$(mktemp -d -t "rhoai-catalog-builder.XXXXXXXXXX")
    log_info "Temp directory: $TMP_DIR"

    # Stash uncommitted changes if needed (only if we'll switch branches)
    if [[ "$DRY_RUN" == false ]] && [[ "$NO_BUILD" == false ]] && [[ -z "$OPERATOR_IMAGE" ]]; then
        if [[ -n "$(git status --porcelain)" ]]; then
            if [[ "$BRANCH" != "$ORIGINAL_BRANCH" ]]; then
                log_warn "Working directory has uncommitted changes"
                log_info "Stashing changes temporarily..."
                if git stash push -u -m "rhoai-catalog-builder auto-stash $(date +%Y%m%d-%H%M%S)" &>/dev/null; then
                    STASHED_CHANGES=true
                    log_success "Changes stashed (will be restored at the end)"
                else
                    log_error "Failed to stash changes. Please commit or stash them manually."
                    exit 1
                fi
            fi
        fi
    fi

    # Check podman login for push registry
    if [[ "$DRY_RUN" == false ]]; then
        local registry_domain
        registry_domain=$(echo "$REGISTRY" | cut -d'/' -f1)
        if ! $IMAGE_BUILDER login --get-login "$registry_domain" &>/dev/null; then
            log_warn "May not be logged into $registry_domain. If push fails, run: $IMAGE_BUILDER login $registry_domain"
        fi
    fi

    # Detect opm binary
    if [[ -f "./bin/opm" ]]; then
        OPM_BIN="./bin/opm"
    elif command -v opm &>/dev/null; then
        OPM_BIN="opm"
    else
        log_info "opm not found, downloading..."
        execute "make opm"
        OPM_BIN="./bin/opm"
    fi

    log_info "Using opm at: $OPM_BIN"
    log_success "All prerequisites met"
}

#######################################
# Build or get the custom operator image
# If --operator-image is set, verify and use it.
# Otherwise, build from --branch using make targets.
#######################################
build_or_get_operator_image() {
    if [[ "$NO_BUILD" == true ]]; then
        log_info "Skipping operator build (--no-build)"
        return
    fi

    if [[ -n "$OPERATOR_IMAGE" ]]; then
        # Use pre-built operator image
        log_info "Using pre-built operator image: $OPERATOR_IMAGE"
        if [[ "$DRY_RUN" == false ]]; then
            if $IMAGE_BUILDER manifest inspect "$OPERATOR_IMAGE" &>/dev/null || \
               $IMAGE_BUILDER image inspect "$OPERATOR_IMAGE" &>/dev/null; then
                log_success "Operator image verified: $OPERATOR_IMAGE"
            else
                log_warn "Could not verify operator image: $OPERATOR_IMAGE (may still work if pushable)"
            fi
        fi
        CUSTOM_OPERATOR_IMG="$OPERATOR_IMAGE"
        return
    fi

    # Build operator from branch
    local operator_tag
    operator_tag="custom-$(echo "$BRANCH" | tr '/' '-')"
    CUSTOM_OPERATOR_IMG="${REGISTRY}/rhods-operator:${operator_tag}"

    log_info "Building operator from branch: $BRANCH"
    log_info "Operator image will be: $CUSTOM_OPERATOR_IMG"

    # Checkout branch if different from current
    if [[ "$BRANCH" != "$ORIGINAL_BRANCH" ]]; then
        execute "git checkout $BRANCH"
    fi

    # Build operator image with CGO_ENABLED=0 for cross-compilation (ARM64 Mac → linux/amd64)
    # Use USE_LOCAL=true to skip re-fetching manifests (faster, preserves local opt/manifests)
    execute "make image-build \
        ODH_PLATFORM_TYPE=rhoai \
        IMG=${CUSTOM_OPERATOR_IMG} \
        CGO_ENABLED=0 \
        USE_LOCAL=true \
        IMAGE_BUILDER=${IMAGE_BUILDER}"

    # Push operator image
    execute "make image-push \
        IMG=${CUSTOM_OPERATOR_IMG} \
        IMAGE_BUILDER=${IMAGE_BUILDER}"

    # Return to original branch if we switched
    if [[ "$BRANCH" != "$ORIGINAL_BRANCH" ]]; then
        execute "git checkout $ORIGINAL_BRANCH"
    fi

    log_success "Operator image built and pushed: $CUSTOM_OPERATOR_IMG"
}

#######################################
# Extract manifests and metadata from a bundle image
# Uses podman create + podman cp (no container run needed)
#
# Args:
#   $1 - bundle image reference
#   $2 - destination directory (will contain manifests/ and metadata/)
#######################################
extract_bundle() {
    local bundle_img=$1
    local dest_dir=$2

    log_info "Extracting bundle: $bundle_img"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would extract manifests/ and metadata/ from $bundle_img"
        return
    fi

    mkdir -p "$dest_dir"

    # Create a container (doesn't run it) to extract files
    local container_id
    container_id=$($IMAGE_BUILDER create --platform linux/amd64 "$bundle_img" 2>/dev/null) || {
        log_error "Failed to create container from $bundle_img"
        log_info "Make sure you can pull: $IMAGE_BUILDER pull $bundle_img"
        return 1
    }

    # Extract manifests and metadata
    $IMAGE_BUILDER cp "$container_id:/manifests" "$dest_dir/manifests" >/dev/null 2>&1 || {
        log_error "Failed to extract /manifests from $bundle_img"
        $IMAGE_BUILDER rm "$container_id" >/dev/null 2>&1 || true
        return 1
    }

    $IMAGE_BUILDER cp "$container_id:/metadata" "$dest_dir/metadata" >/dev/null 2>&1 || {
        log_error "Failed to extract /metadata from $bundle_img"
        $IMAGE_BUILDER rm "$container_id" >/dev/null 2>&1 || true
        return 1
    }

    # Remove the container
    $IMAGE_BUILDER rm "$container_id" >/dev/null 2>&1 || true

    # Verify extraction
    local csv_file
    csv_file=$(find "$dest_dir/manifests" -name '*clusterserviceversion.yaml' -o -name '*clusterserviceversion.yml' 2>/dev/null | head -1)
    if [[ -z "$csv_file" ]]; then
        log_error "No ClusterServiceVersion found in extracted manifests"
        return 1
    fi

    local related_count
    related_count=$(yq '.spec.install.spec.deployments[0].spec.template.spec.containers[0].env[] | select(.name == "RELATED_IMAGE_*" or .name == "RELATED_*") | .name' "$csv_file" 2>/dev/null | wc -l | tr -d ' ')

    log_success "Extracted bundle: $(basename "$csv_file")"
    log_info "  CSV: $csv_file"
    log_info "  RELATED_IMAGE env vars: $related_count"
}

#######################################
# Patch the CSV to replace the operator image
# Keeps all RELATED_IMAGE env vars and other fields intact.
#
# Args:
#   $1 - path to the CSV YAML file
#   $2 - new operator image reference
#######################################
patch_csv() {
    local csv_file=$1
    local new_operator_image=$2

    log_info "Patching CSV with custom operator image: $new_operator_image"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would patch $csv_file with image $new_operator_image"
        return
    fi

    # Show current operator image
    local current_image
    current_image=$(yq '.spec.install.spec.deployments[0].spec.template.spec.containers[0].image' "$csv_file")
    log_info "  Current operator image: $current_image"

    # Patch the deployment container image
    yq -i "
        .spec.install.spec.deployments[0].spec.template.spec.containers[0].image = \"$new_operator_image\"
    " "$csv_file"

    # Patch the metadata annotation
    yq -i "
        .metadata.annotations.containerImage = \"$new_operator_image\"
    " "$csv_file"

    # Verify the patch
    local patched_image
    patched_image=$(yq '.spec.install.spec.deployments[0].spec.template.spec.containers[0].image' "$csv_file")
    if [[ "$patched_image" == "$new_operator_image" ]]; then
        log_success "  Patched operator image: $patched_image"
    else
        log_error "  Patch verification failed. Expected: $new_operator_image, Got: $patched_image"
        return 1
    fi
}

#######################################
# Build a hybrid bundle image
# Extracts production CSV + RELATED_IMAGEs, patches operator image,
# builds a new FROM scratch bundle.
#
# Args:
#   $1 - production bundle image to hybridize
#   $2 - custom operator image to inject
#   $3 - registry to push to
#
# Sets HYBRID_BUNDLE_IMG global variable
#######################################
build_hybrid_bundle() {
    local prod_bundle_img=$1
    local operator_img=$2
    local registry=$3

    log_info "Building hybrid bundle..."
    log_info "  Source bundle: $prod_bundle_img"
    log_info "  Operator image: $operator_img"

    local extract_dir="${TMP_DIR}/hybrid-bundle"

    # Extract production bundle
    extract_bundle "$prod_bundle_img" "$extract_dir" || return 1

    # Generate the hybrid bundle tag from the production bundle tag
    local prod_tag="${prod_bundle_img##*:}"
    HYBRID_BUNDLE_IMG="${registry}/odh-operator-bundle:hybrid-${prod_tag}"

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would build hybrid bundle: $HYBRID_BUNDLE_IMG"
        return
    fi

    # Find the CSV file
    local csv_file
    csv_file=$(find "$extract_dir/manifests" -name '*clusterserviceversion.yaml' -o -name '*clusterserviceversion.yml' 2>/dev/null | head -1)
    if [[ -z "$csv_file" ]]; then
        log_error "No ClusterServiceVersion found in extracted manifests"
        return 1
    fi

    # Patch the CSV with custom operator image
    patch_csv "$csv_file" "$operator_img" || return 1

    # Create a Dockerfile for the hybrid bundle
    local dockerfile="${TMP_DIR}/hybrid-bundle.Dockerfile"
    cat > "$dockerfile" << 'DOCKERFILE'
FROM scratch

# Core bundle labels
LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
LABEL operators.operatorframework.io.bundle.package.v1=rhods-operator
LABEL operators.operatorframework.io.bundle.channels.v1=alpha,stable,fast
LABEL operators.operatorframework.io.bundle.channel.default.v1=stable

COPY manifests /manifests/
COPY metadata /metadata/
DOCKERFILE

    # Build the hybrid bundle image
    log_info "Building hybrid bundle image: $HYBRID_BUNDLE_IMG"
    $IMAGE_BUILDER build --no-cache --load \
        -f "$dockerfile" \
        --platform linux/amd64 \
        -t "$HYBRID_BUNDLE_IMG" \
        "$extract_dir"

    # Push the hybrid bundle
    log_info "Pushing hybrid bundle image..."
    $IMAGE_BUILDER push "$HYBRID_BUNDLE_IMG"

    log_success "Hybrid bundle built and pushed: $HYBRID_BUNDLE_IMG"
}

#######################################
# Build the FBC catalog
# Uses opm render to extract actual bundle names (avoids version mismatch bug
# in hack/update-catalog-template.sh). Builds a proper upgrade chain for N bundles.
#
# Args: none (uses RESOLVED_BUNDLE_IMGS global array)
# Returns: catalog image reference via stdout
#######################################
build_catalog() {
    local catalog_img="${REGISTRY}/opendatahub-operator-catalog:${CATALOG_TAG}"

    log_info "Building catalog with ${#RESOLVED_BUNDLE_IMGS[@]} bundles..."

    # Clean and create catalog directory
    execute "rm -rf catalog"
    execute "mkdir -p catalog"

    if [[ "$DRY_RUN" == true ]]; then
        for img in "${RESOLVED_BUNDLE_IMGS[@]}"; do
            log_info "  [DRY-RUN] Would render: $img"
        done
        log_info "[DRY-RUN] Would build catalog: $catalog_img"
        echo "$catalog_img"
        return
    fi

    log_info "Creating file-based catalog using opm render..."

    local bundle_names=()
    local bundle_files=()

    # Render each bundle to extract its actual name
    local idx=0
    for img in "${RESOLVED_BUNDLE_IMGS[@]}"; do
        idx=$((idx + 1))
        local bundle_file="catalog/bundle${idx}.json"

        log_info "Rendering bundle ${idx}/${#RESOLVED_BUNDLE_IMGS[@]}: $img"

        # Render bundle to JSON
        if ! $OPM_BIN render "$img" > "$bundle_file" 2>/dev/null; then
            log_error "Failed to render bundle: $img"
            log_info "Make sure the bundle is accessible: $IMAGE_BUILDER pull $img"
            exit 1
        fi

        # Extract the actual bundle name from the rendered output
        local bundle_name
        bundle_name=$(jq -r 'select(.schema == "olm.bundle") | .name' "$bundle_file" 2>/dev/null)

        if [[ -z "$bundle_name" ]] || [[ "$bundle_name" == "null" ]]; then
            log_error "Failed to extract bundle name from $img"
            log_info "Rendered content:"
            cat "$bundle_file" >&2
            exit 1
        fi

        log_info "  Bundle name: $bundle_name"
        bundle_names+=("$bundle_name")
        bundle_files+=("$bundle_file")
    done

    # Create catalog.yaml: package declaration
    log_info "Assembling catalog structure..."
    cat > catalog/catalog.yaml << 'EOF'
---
schema: olm.package
name: rhods-operator
defaultChannel: fast
EOF

    # Append each rendered bundle
    for bundle_file in "${bundle_files[@]}"; do
        echo "---" >> catalog/catalog.yaml
        cat "$bundle_file" >> catalog/catalog.yaml
    done

    # Create the upgrade channel with proper replaces chain
    log_info "Creating upgrade channel with ${#bundle_names[@]} entries..."
    cat >> catalog/catalog.yaml << 'EOF'
---
schema: olm.channel
package: rhods-operator
name: fast
entries:
EOF

    # Build the upgrade chain: each bundle replaces the previous one
    local prev_name=""
    for name in "${bundle_names[@]}"; do
        if [[ -z "$prev_name" ]]; then
            # First bundle: no replaces
            echo "  - name: ${name}" >> catalog/catalog.yaml
        else
            # Subsequent bundles: replaces the previous
            echo "  - name: ${name}" >> catalog/catalog.yaml
            echo "    replaces: ${prev_name}" >> catalog/catalog.yaml
        fi
        prev_name="$name"
    done

    # Clean up temporary bundle files
    rm -f catalog/bundle*.json

    # Validate catalog
    log_info "Validating catalog..."
    if $OPM_BIN validate catalog 2>&1; then
        log_success "Catalog validation passed"
    else
        log_error "Catalog validation failed"
        log_info "Catalog content:"
        cat catalog/catalog.yaml >&2
        exit 1
    fi

    # Show catalog summary
    log_info "Catalog contents:"
    log_info "  Package: rhods-operator"
    log_info "  Channel: fast"
    log_info "  Upgrade chain:"
    prev_name=""
    for name in "${bundle_names[@]}"; do
        if [[ -z "$prev_name" ]]; then
            log_info "    ${name} (head)"
        else
            log_info "    ${name} (replaces: ${prev_name})"
        fi
        prev_name="$name"
    done

    # Build catalog image using the project's catalog Dockerfile
    log_info "Building catalog image: $catalog_img"
    $IMAGE_BUILDER build --no-cache --load \
        -f Dockerfiles/catalog.Dockerfile \
        --platform linux/amd64 \
        -t "$catalog_img" .

    # Push catalog image
    log_info "Pushing catalog image..."
    $IMAGE_BUILDER push "$catalog_img"

    log_success "Catalog built and pushed: $catalog_img"
    echo "$catalog_img"
}

#######################################
# Verify catalog contents using opm render
#
# Args:
#   $1 - catalog image reference
#######################################
verify_catalog() {
    local catalog_img=$1

    if [[ "$DRY_RUN" == true ]]; then
        log_info "[DRY-RUN] Would verify catalog: $catalog_img"
        return
    fi

    log_info "Verifying catalog: $catalog_img"

    local render_output="${TMP_DIR}/catalog-render.json"

    if ! $OPM_BIN render "$catalog_img" > "$render_output" 2>/dev/null; then
        log_warn "Could not render catalog for verification (may not be pulled yet)"
        return
    fi

    # Check package exists
    local package_name
    package_name=$(jq -r 'select(.schema == "olm.package") | .name' "$render_output" 2>/dev/null | head -1)
    if [[ "$package_name" == "rhods-operator" ]]; then
        log_success "  Package: rhods-operator"
    else
        log_warn "  Unexpected package name: $package_name"
    fi

    # Count bundles
    local bundle_count
    bundle_count=$(jq -r 'select(.schema == "olm.bundle") | .name' "$render_output" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$bundle_count" -eq "${#RESOLVED_BUNDLE_IMGS[@]}" ]]; then
        log_success "  Bundles: $bundle_count (expected ${#RESOLVED_BUNDLE_IMGS[@]})"
    else
        log_warn "  Bundles: $bundle_count (expected ${#RESOLVED_BUNDLE_IMGS[@]})"
    fi

    # Show channel entries
    log_info "  Channel entries:"
    jq -r 'select(.schema == "olm.channel") | .entries[] | "    - \(.name)" + (if .replaces then " (replaces: \(.replaces))" else " (head)" end)' "$render_output" 2>/dev/null || true

    log_success "Catalog verification complete"
}

#######################################
# Print final summary with CatalogSource YAML
#
# Args:
#   $1 - catalog image reference
#######################################
print_summary() {
    local catalog_img=$1

    echo "" >&2
    echo "======================================" >&2
    log_success "RHOAI Catalog Build Complete!"
    echo "======================================" >&2
    echo "" >&2
    echo "Bundle Images:" >&2
    local idx=1
    for img in "${RESOLVED_BUNDLE_IMGS[@]}"; do
        if [[ "$img" == "$HYBRID_BUNDLE_IMG" ]]; then
            echo "  ${idx}. $img (hybrid)" >&2
        else
            echo "  ${idx}. $img (production)" >&2
        fi
        ((idx++))
    done

    if [[ -n "$CUSTOM_OPERATOR_IMG" ]]; then
        echo "" >&2
        echo "Custom Operator Image:" >&2
        echo "  $CUSTOM_OPERATOR_IMG" >&2
    fi

    echo "" >&2
    echo "Catalog Image:" >&2
    echo "  $catalog_img" >&2
    echo "" >&2
    echo "To use this catalog in OpenShift, create a CatalogSource:" >&2
    echo "" >&2
    cat >&2 << EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-custom-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${catalog_img}
  displayName: "RHOAI Custom Catalog"
  publisher: "Custom"
  updateStrategy:
    registryPoll:
      interval: 10m
EOF
    echo "" >&2
}

#######################################
# Main
#######################################
main() {
    log_info "RHOAI Catalog Builder"
    echo "" >&2

    parse_args "$@"
    validate_args
    check_prerequisites

    # Step 1: Build or get the custom operator image (unless --no-build)
    build_or_get_operator_image

    # Step 2: Resolve bundle images
    # All bundles except the last are used as-is
    # The last bundle is hybridized (unless --no-build)
    local last_idx=$(( ${#BUNDLE_SPECS[@]} - 1 ))

    for i in "${!BUNDLE_SPECS[@]}"; do
        if [[ "$i" -eq "$last_idx" ]] && [[ "$NO_BUILD" == false ]]; then
            # Hybridize the last bundle
            build_hybrid_bundle "${BUNDLE_SPECS[$i]}" "$CUSTOM_OPERATOR_IMG" "$REGISTRY" || {
                log_error "Failed to build hybrid bundle"
                exit 1
            }
            RESOLVED_BUNDLE_IMGS+=("$HYBRID_BUNDLE_IMG")
        else
            # Use as-is
            RESOLVED_BUNDLE_IMGS+=("${BUNDLE_SPECS[$i]}")
        fi
    done

    log_info "Resolved bundle images:"
    for img in "${RESOLVED_BUNDLE_IMGS[@]}"; do
        log_info "  - $img"
    done

    # Step 3: Build and push catalog
    local catalog_img
    catalog_img=$(build_catalog)

    # Step 4: Verify catalog
    verify_catalog "$catalog_img"

    # Step 5: Print summary
    print_summary "$catalog_img"
}

main "$@"
