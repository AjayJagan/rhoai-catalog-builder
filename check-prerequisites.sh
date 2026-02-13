#!/bin/bash

set -euo pipefail

echo "Checking prerequisites for RHOAI Catalog Builder..."
echo ""

MISSING=()

# Check for required commands
for cmd in podman git jq yq opm; do
    if command -v "$cmd" &> /dev/null; then
        version=$("$cmd" --version 2>&1 | head -1 || echo "version unknown")
        echo "✓ $cmd: $version"
    else
        echo "✗ $cmd: NOT FOUND"
        MISSING+=("$cmd")
    fi
done

echo ""

if [ ${#MISSING[@]} -eq 0 ]; then
    echo "✓ All required tools are installed!"

    # Check registry login
    echo ""
    echo "Checking registry authentication..."
    if podman login --get-login quay.io &>/dev/null; then
        user=$(podman login --get-login quay.io 2>/dev/null || echo "unknown")
        echo "✓ Logged into quay.io as: $user"
    else
        echo "⚠ Not logged into quay.io"
        echo "  Run: podman login quay.io"
    fi

    # Check yq version (need v4)
    echo ""
    echo "Checking yq version..."
    yq_version=$(yq --version 2>&1 | grep -o 'version.*' | cut -d' ' -f2 || echo "unknown")
    if [[ "$yq_version" =~ ^v?4\. ]]; then
        echo "✓ yq version: $yq_version (v4.x required)"
    else
        echo "⚠ yq version: $yq_version (v4.x required, found different version)"
        echo "  Install yq v4: brew install yq"
    fi

    echo ""
    echo "🎉 Ready to build RHOAI catalogs!"
    echo ""
    echo "Next steps:"
    echo "  1. Read QUICKSTART.md for common workflows"
    echo "  2. Try a dry-run: ./rhoai-catalog-builder.sh --help"
else
    echo "✗ Missing prerequisites: ${MISSING[*]}"
    echo ""
    echo "Install missing tools on macOS:"
    echo "  brew install ${MISSING[*]}"
    echo ""
    echo "Or see README.md for installation instructions"
    exit 1
fi
