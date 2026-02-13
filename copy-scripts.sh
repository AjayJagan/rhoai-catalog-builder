#!/bin/bash

set -euo pipefail

# Path to opendatahub-operator repository
ODH_REPO="${ODH_REPO:-$HOME/work/rhoai/opendatahub-operator}"

echo "Copying scripts from opendatahub-operator repository..."
echo "Source: $ODH_REPO"
echo ""

# Check if source repository exists
if [ ! -d "$ODH_REPO" ]; then
    echo "Error: opendatahub-operator repository not found at: $ODH_REPO"
    echo ""
    echo "Set ODH_REPO environment variable to correct path:"
    echo "  export ODH_REPO=/path/to/opendatahub-operator"
    echo "  ./copy-scripts.sh"
    exit 1
fi

# Array of scripts to copy: source:destination
SCRIPTS=(
    "scripts/rhoai-catalog-builder.sh:rhoai-catalog-builder.sh"
    "verify-bundle-commit.sh:verify-bundle-commit.sh"
    "scripts/verify-catalog-commit.sh:verify-catalog-commit.sh"
)

for script_pair in "${SCRIPTS[@]}"; do
    src="${script_pair%%:*}"
    dst="${script_pair##*:}"

    src_path="$ODH_REPO/$src"
    dst_path="$PWD/$dst"

    if [ -f "$src_path" ]; then
        echo "✓ Copying: $src → $dst"
        cp "$src_path" "$dst_path"
        chmod +x "$dst_path"
    else
        echo "✗ Not found: $src_path"
        echo "  Skipping..."
    fi
done

echo ""
echo "Done! Verifying scripts..."
echo ""

# Verify scripts
for script_pair in "${SCRIPTS[@]}"; do
    dst="${script_pair##*:}"

    if [ -f "$dst" ] && [ -x "$dst" ]; then
        echo "✓ $dst is ready"
    else
        echo "✗ $dst is missing or not executable"
    fi
done

echo ""
echo "Next steps:"
echo "  1. Review the copied scripts"
echo "  2. Test with: ./rhoai-catalog-builder.sh --help"
echo "  3. Initialize git: git init && git add . && git commit -m 'Initial commit'"
