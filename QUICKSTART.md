# Quick Start Guide

## TL;DR - Most Common Workflow

Test RHOAI 2.25 → 3.3 upgrade with custom operator from your feature branch:

```bash
# 1. Build catalog with hybrid bundle (uses your pre-built operator image)
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --operator-image quay.io/yourusername/rhods-operator:custom-test-hwp-change

# 2. Verify the hybrid bundle
./verify-bundle-commit.sh \
  quay.io/yourusername/odh-operator-bundle:hybrid-rhoai-3.3

# 3. Verify commit in catalog
./verify-catalog-commit.sh \
  --rhoai-version v3.3 \
  --search 21849199b \
  --catalog quay.io/yourusername/opendatahub-operator-catalog:rhoai-2.25-to-hybrid-rhoai-3.3

# 4. Deploy catalog to OpenShift
cat <<EOF | oc apply -f -
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
EOF
```

## Common Commands

### Build Operator Image First (if needed)

```bash
cd /path/to/opendatahub-operator
git checkout test-hwp-change

make image-build \
  ODH_PLATFORM_TYPE=rhoai \
  IMG=quay.io/yourusername/rhods-operator:custom-test-hwp-change \
  CGO_ENABLED=0

make image-push \
  IMG=quay.io/yourusername/rhods-operator:custom-test-hwp-change
```

### Build Catalog from Current Branch

Instead of pre-building operator image, let the script build from current branch:

```bash
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --branch test-hwp-change
```

### Three-Version Chain

```bash
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.2 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --operator-image quay.io/yourusername/rhods-operator:custom
```

### Dry-Run (Preview)

```bash
./rhoai-catalog-builder.sh \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-2.25 \
  --bundle quay.io/rhoai/odh-operator-bundle:rhoai-3.3 \
  --registry quay.io/yourusername \
  --dry-run
```

## What Gets Created

After running `rhoai-catalog-builder.sh`, you get:

1. **Hybrid Bundle** (last bundle only, if not using `--no-build`):
   - Image: `quay.io/yourusername/odh-operator-bundle:hybrid-rhoai-3.3`
   - Contents: Production CSV + RELATED_IMAGEs, patched operator image

2. **Catalog**:
   - Image: `quay.io/yourusername/opendatahub-operator-catalog:rhoai-2.25-to-hybrid-rhoai-3.3`
   - Contents: FBC YAML with package, bundles, and upgrade channel

## Verification Checklist

Before deploying to OpenShift:

- [ ] Hybrid bundle has correct operator image
  ```bash
  ./verify-bundle-commit.sh <hybrid-bundle-image>
  ```

- [ ] RELATED_IMAGE count is 94+ (production images preserved)

- [ ] Commit SHA matches your feature branch
  ```bash
  ./verify-catalog-commit.sh --rhoai-version v3.3 --search <commit> --catalog <catalog-image>
  ```

- [ ] Catalog renders without errors
  ```bash
  opm render <catalog-image> | jq '.'
  ```

## Troubleshooting One-Liners

```bash
# Check if operator image has commit label
podman inspect quay.io/yourusername/rhods-operator:custom | \
  jq -r '.[0].Labels["org.opencontainers.image.revision"]'

# List all bundles in catalog
opm render quay.io/yourusername/catalog:tag | \
  jq -r 'select(.schema == "olm.bundle") | .name'

# Check upgrade path in catalog
opm render quay.io/yourusername/catalog:tag | \
  jq -r 'select(.schema == "olm.channel") | .entries[]'

# Verify registry login
podman login --get-login quay.io

# Test bundle pull
podman pull quay.io/rhoai/odh-operator-bundle:rhoai-3.3
```

## Tips

- Use `--dry-run` first to see what will happen
- Always verify bundles before deploying to clusters
- Use descriptive catalog tags (include date, ticket number, etc.)
- Keep verification output for your records
- Test in non-production clusters first

## Quick Reference Card

| Task | Command |
|------|---------|
| Build catalog with pre-built operator | `--operator-image <image>` |
| Build catalog from branch | `--branch <branch-name>` |
| Use all pre-existing bundles | `--no-build` |
| Preview without executing | `--dry-run` |
| Custom catalog tag | `--catalog-tag <tag>` |
| Verify bundle | `./verify-bundle-commit.sh <bundle>` |
| Search for commit | `./verify-catalog-commit.sh --rhoai-version v3.3 --search <commit> --catalog <catalog>` |
