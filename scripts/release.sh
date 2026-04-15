#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Release preparation script for clio-helper
#
# Usage: ./scripts/release.sh VERSION
# Example: ./scripts/release.sh 20260415.1

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

step() {
    echo -e "${BLUE}${BOLD}==>${NC}${BOLD} $1${NC}"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

error() {
    echo -e "${RED}✗ ERROR:${NC} $1" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}!${NC} $1"
}

# -- Validate arguments -------------------------------------------------------

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "Usage: $0 VERSION"
    echo "Example: $0 20260415.1"
    exit 1
fi

if ! echo "$VERSION" | grep -qE '^[0-9]{8}\.[0-9]+$'; then
    error "Invalid version format: $VERSION (expected YYYYMMDD.N)"
fi

echo ""
echo -e "${BOLD}Preparing clio-helper release ${VERSION}${NC}"
echo ""

# -- Pre-flight checks --------------------------------------------------------

step "Checking for uncommitted changes..."
if ! git diff --quiet HEAD 2>/dev/null; then
    error "Uncommitted changes found. Commit or stash before releasing."
fi
success "Working tree is clean"

step "Checking if tag ${VERSION} already exists..."
if git tag -l "$VERSION" | grep -q "^${VERSION}$"; then
    error "Tag ${VERSION} already exists"
fi
success "Tag ${VERSION} is available"

# -- Update version ------------------------------------------------------------

step "Updating version in clio-helper to ${VERSION}..."
sed -i.bak "s/our \$VERSION = '[^']*';/our \$VERSION = '$VERSION';/" clio-helper
rm -f clio-helper.bak
ACTUAL=$(grep "our \$VERSION" clio-helper | head -1 | sed "s/.*'\(.*\)'.*/\1/")
if [ "$ACTUAL" != "$VERSION" ]; then
    error "Version update failed (got ${ACTUAL}, expected ${VERSION})"
fi
success "Version updated to ${VERSION}"

# -- Commit and tag ------------------------------------------------------------

step "Committing version bump..."
git add clio-helper
git commit -m "chore(release): prepare version ${VERSION}"
success "Committed"

step "Creating annotated tag ${VERSION}..."
git tag -a "${VERSION}" -m "clio-helper ${VERSION}"
success "Tag ${VERSION} created"

# -- Done ----------------------------------------------------------------------

echo ""
echo -e "${GREEN}${BOLD}Release ${VERSION} prepared successfully!${NC}"
echo ""
echo -e "Next steps:"
echo -e "  ${BOLD}git push origin main${NC}          # push commits"
echo -e "  ${BOLD}git push origin ${VERSION}${NC}   # push tag"
echo ""
