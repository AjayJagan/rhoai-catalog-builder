# Rewrite `rhoai-catalog-builder.sh` — Hybrid Bundle with RELATED_IMAGE Extraction

## Context

When testing RHOAI operator upgrades (e.g., 2.25 → 3.3), we need a custom OLM catalog containing:
1. **Older version** (e.g., 2.25): Use the existing production bundle image as-is
2. **Target version** (e.g., 3.3): A **hybrid bundle** that extracts the production CSV + all 94+ `RELATED_IMAGE` env vars from the production bundle, then swaps only the operator image with a custom-built one from a feature branch

This ensures the test catalog is production-faithful (all component images match prod) while testing custom operator changes.

**Problems with the current script:**
- No hybrid bundle support — can only use pre-existing bundles or build entirely from scratch
- The `hack/update-catalog-template.sh` has a version mismatch bug (extracts version from image tag `rhoai-2.25` but actual CSV version is `2.25.2`, causing `opm validate` failure)
- Limited to exactly 2 bundles in version mode
- No RELATED_IMAGE extraction capability

**Solution:** Full rewrite of `scripts/rhoai-catalog-builder.sh` as a single file. The script uses `opm render` + `jq` to extract actual bundle names (avoiding the version mismatch), and `podman create` + `podman cp` to extract CSV manifests from production bundles for hybridization.

## File to Modify

- `scripts/rhoai-catalog-builder.sh` — full rewrite (single file, ~600 lines)

## CLI Interface

### Flags

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--bundle <spec>` | Yes (1+) | — | Bundle image to include (repeatable, order = upgrade chain) |
| `--registry <reg>` | Yes | — | Push registry (e.g., `quay.io/ajaganat`) |
| `--branch <name>` | No | current branch | Branch to build custom operator from |
| `--operator-image <img>` | No | — | Pre-built operator image (skips operator build) |
| `--catalog-tag <tag>` | No | auto-generated | Tag for the catalog image |
| `--no-build` | No | false | Use all bundles as-is (no hybrid, no operator build) |
| `--image-builder <cmd>` | No | `podman` | Container build tool |
| `--dry-run` | No | false | Print commands without executing |
| `--help` | No | — | Show usage |

### Core Behavior

- **All bundles except the last** are used as-is (pre-existing production images)
- **The last `--bundle`** is automatically hybridized: its CSV and RELATED_IMAGEs are extracted from the production image, the operator image reference is swapped with the custom-built one, and a new hybrid bundle image is built and pushed
- If `--no-build` is passed, ALL bundles are used as-is (useful for testing with only pre-existing images)
- If `--operator-image` is provided, that image is used for the hybrid bundle instead of building from the current branch

### Example Invocations

```bash
# Upgrade test: 2.25 → 3.3 with custom operator from current branch
./scripts/rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/ajaganat

# Same but specify which branch to build from
./scripts/rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/ajaganat \
  --branch test-hwp-change

# Use a pre-built operator image (skip operator build)
./scripts/rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/ajaganat \
  --operator-image quay.io/ajaganat/rhods-operator:custom-rhoai-3.3

# Three-version upgrade chain (2.25 → 3.2 → 3.3)
./scripts/rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.2 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/ajaganat \
  --catalog-tag v2.25-3.2-3.3

# All pre-existing bundles (no hybrid, no build)
./scripts/rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/ajaganat \
  --no-build
```

## Detailed Design

### Script Flow

```
main()
  parse_args "$@"
  validate_args
  check_prerequisites          # podman, git, jq, opm; repo root; stash; registry login
  build_or_get_operator_image  # build from branch OR use --operator-image
  build_hybrid_bundle          # extract prod CSV → patch operator image → build+push
  build_catalog                # opm render each bundle → assemble catalog.yaml → build+push
  verify_catalog               # opm render catalog image → verify package/bundles/channel
  print_summary                # images, CatalogSource YAML
```

### Key Functions

#### 1. `build_or_get_operator_image()`

If `--operator-image` is provided, verify it's accessible and use it. Otherwise:

1. Save current branch, stash changes
2. Checkout `--branch` (default: current branch, so no checkout needed if already there)
3. Build operator: `make image-build ODH_PLATFORM_TYPE=rhoai IMG=<registry>/rhods-operator:<tag> CGO_ENABLED=0`
4. Push: `make image-push IMG=<registry>/rhods-operator:<tag>`
5. Return to original branch, pop stash

The `CGO_ENABLED=0` is required for cross-compilation (ARM64 Mac → linux/amd64).

The operator image tag defaults to the branch name or a generated tag based on git SHA.

#### 2. `extract_bundle(bundle_img, dest_dir)`

Extracts manifests and metadata from a production bundle image using podman:

```bash
container_id=$(podman create --platform linux/amd64 "$bundle_img" 2>/dev/null)
podman cp "$container_id:/manifests" "$dest_dir/manifests"
podman cp "$container_id:/metadata" "$dest_dir/metadata"
podman rm "$container_id" >/dev/null 2>&1
```

This gives us the full CSV (with all RELATED_IMAGE env vars) and CRDs.

#### 3. `patch_csv(csv_file, new_operator_image)`

Patches the extracted CSV to replace the operator image while keeping everything else:

Using `yq` (already a project dependency):
```bash
# Patch the deployment container image
yq -i '
  .spec.install.spec.deployments[0].spec.template.spec.containers[0].image = "'"$new_operator_image"'"
' "$csv_file"

# Patch the metadata annotation
yq -i '
  .metadata.annotations.containerImage = "'"$new_operator_image"'"
' "$csv_file"
```

All RELATED_IMAGE env vars in `spec.install.spec.deployments[0].spec.template.spec.containers[0].env[]` remain untouched.

#### 4. `build_hybrid_bundle(bundle_img, operator_img, registry)`

1. Create temp dir, call `extract_bundle()` to get manifests/metadata
2. Find the CSV file: `ls $dest_dir/manifests/*clusterserviceversion.yaml`
3. Call `patch_csv()` to swap the operator image
4. Build a `FROM scratch` bundle image with the patched manifests:
   ```dockerfile
   FROM scratch
   LABEL operators.operatorframework.io.bundle.mediatype.v1=registry+v1
   LABEL operators.operatorframework.io.bundle.manifests.v1=manifests/
   LABEL operators.operatorframework.io.bundle.metadata.v1=metadata/
   LABEL operators.operatorframework.io.bundle.package.v1=rhods-operator
   LABEL operators.operatorframework.io.bundle.channels.v1=alpha,stable,fast
   LABEL operators.operatorframework.io.bundle.channel.default.v1=stable
   COPY manifests /manifests/
   COPY metadata /metadata/
   ```
5. Tag as `<registry>/odh-operator-bundle:hybrid-<tag>` and push
6. Return the hybrid bundle image reference

#### 5. `build_catalog(bundle_images_array)`

Builds the FBC catalog directly using `opm render` (bypasses `hack/update-catalog-template.sh` entirely, avoiding the version mismatch bug):

1. **Render each bundle** to extract actual bundle name:
   ```bash
   for img in "${bundle_images[@]}"; do
       opm render "$img" > "catalog/bundle${idx}.json"
       bundle_name=$(jq -r 'select(.schema == "olm.bundle") | .name' "catalog/bundle${idx}.json")
   done
   ```

2. **Assemble `catalog/catalog.yaml`**:
   ```yaml
   ---
   schema: olm.package
   name: rhods-operator
   defaultChannel: fast
   ---
   # Each rendered bundle (JSON from opm render) appended here
   ---
   schema: olm.channel
   package: rhods-operator
   name: fast
   entries:
     - name: rhods-operator.2.25.2          # first bundle, no replaces
     - name: rhods-operator.3.3.0           # second, replaces first
       replaces: rhods-operator.2.25.2
     # ... N bundles with linear upgrade chain
   ```

3. **Validate**: `opm validate catalog`

4. **Build catalog image** using `Dockerfiles/catalog.Dockerfile`:
   ```bash
   podman build --no-cache --load \
     -f Dockerfiles/catalog.Dockerfile \
     --platform linux/amd64 \
     -t "$catalog_img" .
   ```

5. **Push**: `podman push "$catalog_img"`

This approach extracts the **actual** bundle name from inside the bundle (e.g., `rhods-operator.2.25.2`) rather than deriving it from the image tag, completely avoiding the version mismatch.

#### 6. `verify_catalog(catalog_img)`

After push, render the catalog and verify:
```bash
opm render "$catalog_img" | jq -s '.'
```

Check:
- Package `rhods-operator` exists
- Expected number of `olm.bundle` entries
- Channel `fast` has correct upgrade chain (each entry after first has `replaces`)
- Print human-readable summary of upgrade path

#### 7. `cleanup()`

Trap handler for `EXIT` (covers ERR, INT, TERM):
- Guard variable to prevent double execution
- Return to original git branch (if switched)
- Clean temp dirs and generated artifacts (`catalog/`, temp extraction dirs)
- Pop stash if we stashed changes
- Remove podman containers created for extraction

### Catalog Tag Auto-Generation

When `--catalog-tag` is not provided, auto-generate from bundle image tags:
```bash
# Extract tags from bundle images
# quay.io/rhoai/odh-operator-bundle:rhoai-2.25 → rhoai-2.25
# Result: "rhoai-2.25-to-rhoai-3.3-hybrid"
```

## What We Reuse from Current Script

- **Logging functions** (`log_info`, `log_success`, `log_warn`, `log_error`) — keep as-is
- **`execute()` function** for dry-run support — keep as-is
- **`check_prerequisites()` pattern** — adapt (add `jq` to required commands, keep opm detection)
- **`cleanup()` pattern** — adapt (add temp dir cleanup, podman container cleanup)
- **`build_catalog()` approach** using `opm render` + `jq` for extracting actual bundle names — this is the correct approach already in the script (lines 501-652), adapt for N bundles
- **CatalogSource YAML in `print_summary()`** — keep

## What We Remove

- `--version1` / `--version2` flags and all version-mode logic
- `--custom-bundles` flag
- `check_bundle_available()` function (registry checking for version resolution)
- `version_to_branch()` function
- `build_and_push_version()` function (replaced by hybrid bundle approach)
- Inline catalog Dockerfile (use `Dockerfiles/catalog.Dockerfile` instead)

## Verification

1. **Dry-run**: `./scripts/rhoai-catalog-builder.sh --bundle img1 --bundle img2 --registry quay.io/test --dry-run` — verify logged commands, no execution
2. **Full hybrid build**: `--bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 --registry quay.io/ajaganat` — verify:
   - Operator built from current branch with `CGO_ENABLED=0`
   - Production rhoai-3.3 bundle extracted, CSV patched, RELATED_IMAGEs preserved
   - Hybrid bundle built and pushed
   - Catalog built with correct upgrade chain (`rhods-operator.2.25.2` → `rhods-operator.3.3.0`)
   - `opm render` verification passes
3. **No-build mode**: `--no-build` — verify no operator build, no hybrid, all bundles as-is
4. **Pre-built operator**: `--operator-image quay.io/ajaganat/rhods-operator:custom` — verify operator build skipped
5. **Signal handling**: Send SIGINT mid-build, verify git state restored and stash popped
