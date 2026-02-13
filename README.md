# RHOAI Catalog Builder Tools

A collection of scripts for building and verifying custom RHOAI (Red Hat OpenShift AI) operator catalogs for upgrade testing.

## Overview

These tools help you test RHOAI operator upgrades by creating custom OLM (Operator Lifecycle Manager) catalogs that combine:
- Production bundles from published registries
- Hybrid bundles with custom operator images (for testing feature branches)
- Full verification of commits and RELATED_IMAGE environment variables

## Tools Included

### 1. `rhoai-catalog-builder.sh`
Builds custom OLM catalogs with hybrid bundle support.

**Key features:**
- Extracts production CSVs with all 94+ RELATED_IMAGE vars from production bundles
- Patches operator image reference while preserving all component images
- Supports N bundles in upgrade chain
- Validates catalog with `opm validate`
- Auto-stashes git changes and restores them after build

### 2. `verify-bundle-commit.sh`
Verifies operator images in bundles and extracts RELATED_IMAGE variables.

**Key features:**
- Extracts bundle manifests using podman
- Shows operator image reference from CSV
- Displays RELATED_IMAGE variables (first 5 and total count)
- Checks operator image labels for git commit SHA

### 3. `verify-catalog-commit.sh`
Searches catalogs for specific commits in bundle versions.

**Key features:**
- Renders catalog to extract all bundles
- Filters bundles by version pattern
- Checks operator image labels for commit SHA
- Supports full or short commit SHA matching

## Prerequisites

### Required Tools
```bash
# Check if tools are installed
which podman git jq yq opm

# Install if missing (macOS with Homebrew)
brew install podman jq yq opm
```

### Registry Authentication
```bash
# Login to your push registry
podman login quay.io

# Verify access to RHOAI bundles (optional, for production bundles)
podman login quay.io
```

### Repository Setup
Clone the opendatahub-operator repository:
```bash
git clone https://github.com/red-hat-data-services/opendatahub-operator.git
cd opendatahub-operator
```

## Installation

Copy the scripts to your PATH or use them directly from this repository:

```bash
# Option 1: Add to PATH
cp rhoai-catalog-builder.sh ~/bin/
cp verify-bundle-commit.sh ~/bin/
cp verify-catalog-commit.sh ~/bin/
chmod +x ~/bin/*.sh

# Option 2: Use directly
./rhoai-catalog-builder.sh --help
```

## Usage

### Basic Workflow: Testing Operator Upgrades

**Scenario:** Test upgrade from RHOAI 2.25 → 3.3 with custom operator from feature branch

#### Step 1: Build Custom Operator Image

```bash
cd /path/to/opendatahub-operator

# Checkout your feature branch
git checkout test-hwp-change

# Build operator image
make image-build \
  ODH_PLATFORM_TYPE=rhoai \
  IMG=quay.io/yourusername/rhods-operator:custom-test-hwp-change \
  CGO_ENABLED=0

# Push operator image
make image-push \
  IMG=quay.io/yourusername/rhods-operator:custom-test-hwp-change
```

#### Step 2: Build Catalog with Hybrid Bundle

```bash
# Using the pre-built operator image
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --operator-image quay.io/yourusername/rhods-operator:custom-test-hwp-change

# Or build operator from current branch automatically
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --branch test-hwp-change
```

**Output:**
- Hybrid bundle: `quay.io/yourusername/odh-operator-bundle:hybrid-rhoai-3.3`
- Catalog: `quay.io/yourusername/opendatahub-operator-catalog:rhoai-2.25-to-hybrid-rhoai-3.3`

#### Step 3: Verify the Hybrid Bundle

```bash
# Check what's in the hybrid bundle
./verify-bundle-commit.sh \
  quay.io/yourusername/odh-operator-bundle:hybrid-rhoai-3.3
```

**Expected output:**
```
=== Operator Image in Bundle ===
quay.io/yourusername/rhods-operator:custom-test-hwp-change

=== CSV Metadata Annotation ===
quay.io/yourusername/rhods-operator:custom-test-hwp-change

=== Verifying Operator Image Labels ===
Git commit: 21849199b7179dc3074812b8e24698ec609d6a5c

=== Sample RELATED_IMAGE Variables (first 5) ===
RELATED_IMAGE_ODH_DASHBOARD_IMAGE: quay.io/rhoai/odh-dashboard:rhoai-3.3
RELATED_IMAGE_ODH_NOTEBOOK_CONTROLLER_IMAGE: quay.io/rhoai/odh-notebook-controller:rhoai-3.3
RELATED_IMAGE_KSERVE_CONTROLLER_IMAGE: quay.io/rhoai/kserve-controller:rhoai-3.3
...

=== Total RELATED_IMAGE Variables ===
Count: 94
```

#### Step 4: Verify Commit in Catalog

```bash
# Search for your commit in the catalog
./verify-catalog-commit.sh \
  --rhoai-version v3.3 \
  --search 21849199b \
  --catalog quay.io/yourusername/opendatahub-operator-catalog:rhoai-2.25-to-hybrid-rhoai-3.3
```

**Expected output:**
```
✓ Commit FOUND!

  Bundle:         rhods-operator.3.3.0 (quay.io/yourusername/odh-operator-bundle:hybrid-rhoai-3.3)
  Operator Image: quay.io/yourusername/rhods-operator:custom-test-hwp-change
  Git Commit:     21849199b7179dc3074812b8e24698ec609d6a5c
```

### Advanced Usage

#### Three-Version Upgrade Chain

Test 2.25 → 3.2 → 3.3:

```bash
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.2 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --operator-image quay.io/yourusername/rhods-operator:custom-rhoai-3.3
```

#### No-Build Mode (Use All Pre-existing Bundles)

```bash
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --no-build
```

#### Custom Catalog Tag

```bash
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --catalog-tag my-test-catalog-v1
```

#### Dry-Run Mode

Preview what would happen without executing:

```bash
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --dry-run
```

## Using the Catalog in OpenShift

After building your catalog, deploy it to your OpenShift cluster:

```yaml
# catalog-source.yaml
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: rhoai-custom-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: quay.io/yourusername/opendatahub-operator-catalog:rhoai-2.25-to-hybrid-rhoai-3.3
  displayName: "RHOAI Custom Test Catalog"
  publisher: "Testing"
  updateStrategy:
    registryPoll:
      interval: 10m
```

Apply it:
```bash
oc apply -f catalog-source.yaml

# Wait for catalog to be ready
oc get catalogsource -n openshift-marketplace -w

# The operator should now appear in OperatorHub
```

## How It Works

### Hybrid Bundle Creation

The `rhoai-catalog-builder.sh` script creates hybrid bundles by:

1. **Extracting production bundle** using `podman create` + `podman cp`
   ```bash
   container_id=$(podman create quay.io/rhoai/odh-operator-bundle:rhoai-3.3)
   podman cp "$container_id:/manifests" ./temp/manifests
   ```

2. **Finding the CSV** in extracted manifests
   ```bash
   csv_file=$(find ./temp/manifests -name '*clusterserviceversion.yaml')
   ```

3. **Patching operator image** using `yq` (only 2 YAML paths modified)
   ```bash
   yq -i '.spec.install.spec.deployments[0].spec.template.spec.containers[0].image = "custom-image"' "$csv_file"
   yq -i '.metadata.annotations.containerImage = "custom-image"' "$csv_file"
   ```

4. **Preserving RELATED_IMAGE vars** - All 94+ environment variables remain untouched:
   ```yaml
   env:
     - name: RELATED_IMAGE_ODH_DASHBOARD_IMAGE
       value: quay.io/rhoai/odh-dashboard:rhoai-3.3
     - name: RELATED_IMAGE_KSERVE_CONTROLLER_IMAGE
       value: quay.io/rhoai/kserve-controller:rhoai-3.3
     # ... 92+ more
   ```

5. **Building new bundle** with patched manifests
   ```dockerfile
   FROM scratch
   COPY manifests /manifests/
   COPY metadata /metadata/
   ```

### Catalog Assembly

The script uses `opm render` + `jq` to avoid version mismatch bugs:

```bash
# Render each bundle to extract actual name
opm render quay.io/rhoai/odh-operator-bundle:rhoai-2.25 > bundle1.json
bundle_name=$(jq -r 'select(.schema == "olm.bundle") | .name' bundle1.json)
# Result: "rhods-operator.2.25.2" (actual CSV name, not derived from tag)

# Build catalog with correct upgrade chain
cat > catalog/catalog.yaml <<EOF
---
schema: olm.package
name: rhods-operator
defaultChannel: fast
---
# Bundle 1 (from opm render)
---
# Bundle 2 (from opm render)
---
schema: olm.channel
package: rhods-operator
name: fast
entries:
  - name: rhods-operator.2.25.2
  - name: rhods-operator.3.3.0
    replaces: rhods-operator.2.25.2
EOF
```

## Troubleshooting

### Issue: "Bundle image not accessible"

**Solution:** Verify registry login
```bash
podman login quay.io
podman pull quay.io/rhoai/odh-operator-bundle:rhoai-3.3
```

### Issue: "No git commit found in operator image labels"

**Cause:** Operator image doesn't have OCI labels set

**Solution:** Check if your build process sets labels:
```bash
podman inspect quay.io/yourusername/rhods-operator:custom | \
  jq '.[0].Labels["org.opencontainers.image.revision"]'
```

### Issue: Catalog validation fails

**Symptom:** `opm validate catalog` shows errors

**Solution:** Check catalog structure
```bash
# Render catalog to see what's inside
opm render quay.io/yourusername/opendatahub-operator-catalog:tag | jq '.'

# Check for bundle name mismatches
jq 'select(.schema == "olm.bundle") | .name' catalog.json
jq 'select(.schema == "olm.channel") | .entries[].name' catalog.json
```

### Issue: "No bundles found matching version"

**Cause:** Version pattern doesn't match bundle names in catalog

**Solution:** Check available bundles
```bash
opm render quay.io/yourusername/catalog:tag | \
  jq -r 'select(.schema == "olm.bundle") | .name'
```

### Issue: RELATED_IMAGE variables missing in hybrid bundle

**Cause:** CSV patching modified more than just operator image

**Verification:** Check the `patch_csv()` function only modifies these paths:
- `.spec.install.spec.deployments[0].spec.template.spec.containers[0].image`
- `.metadata.annotations.containerImage`

All other CSV fields (including `.spec.install.spec.deployments[0].spec.template.spec.containers[0].env[]`) remain unchanged.

## Script Reference

### rhoai-catalog-builder.sh

```
Usage: rhoai-catalog-builder.sh [OPTIONS]

Flags:
  --bundle <image>              Bundle image to include (repeatable, order = upgrade chain)
  --registry <reg>              Push registry (e.g., quay.io/username)
  --branch <name>               Branch to build operator from (default: current branch)
  --operator-image <img>        Pre-built operator image (skips operator build)
  --catalog-tag <tag>           Tag for catalog image (default: auto-generated)
  --no-build                    Use all bundles as-is (no hybrid, no operator build)
  --image-builder <cmd>         Container build tool (default: podman)
  --dry-run                     Print commands without executing
  --help                        Show usage
```

### verify-bundle-commit.sh

```
Usage: verify-bundle-commit.sh <bundle-image>

Example:
  verify-bundle-commit.sh quay.io/yourusername/odh-operator-bundle:hybrid-rhoai-3.3
```

### verify-catalog-commit.sh

```
Usage: verify-catalog-commit.sh --rhoai-version <version> --search <commit> --catalog <image>

Flags:
  --rhoai-version <version>     RHOAI version to search (e.g., v3.3, 3.3, rhoai-3.3)
  --search <commit-sha>         Git commit SHA to search for (full or short)
  --catalog <catalog-image>     Catalog image to inspect
  --image-builder <cmd>         Container tool (default: podman)
  --help                        Show usage

Example:
  verify-catalog-commit.sh \
    --rhoai-version v3.3 \
    --search 21849199b \
    --catalog quay.io/yourusername/catalog:tag
```

## Best Practices

1. **Always verify bundles before using in production**
   ```bash
   ./verify-bundle-commit.sh <bundle-image>
   ```

2. **Use descriptive catalog tags**
   ```bash
   --catalog-tag "rhoai-2.25-to-3.3-hwp-fix-$(date +%Y%m%d)"
   ```

3. **Test catalogs in non-production clusters first**

4. **Keep track of which commit is in which catalog**
   ```bash
   # Save verification output
   ./verify-catalog-commit.sh \
     --rhoai-version v3.3 \
     --search <commit> \
     --catalog <catalog-image> \
     > catalog-verification.txt
   ```

5. **Use `--dry-run` to preview builds**

## Contributing

If you find bugs or have suggestions for improvements, please open an issue or submit a pull request.

## License

MIT

## Related Resources

- [OLM Documentation](https://olm.operatorframework.io/)
- [opm CLI Reference](https://olm.operatorframework.io/docs/cli/opm/)
- [File-Based Catalogs](https://olm.operatorframework.io/docs/reference/file-based-catalogs/)
- [opendatahub-operator Repository](https://github.com/red-hat-data-services/opendatahub-operator)
