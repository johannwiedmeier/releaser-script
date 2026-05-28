#!/usr/bin/env bash
set -euo pipefail

# ─── Colors & Formatting ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ─── Helpers ────────────────────────────────────────────────────────────────────
die()  { echo -e "${RED}✖ $1${RESET}" >&2; exit 1; }
info() { echo -e "${BLUE}ℹ ${RESET}$1"; }
ok()   { echo -e "${GREEN}✔ ${RESET}$1"; }
warn() { echo -e "${YELLOW}⚠ ${RESET}$1"; }

confirm() {
    local prompt="$1"
    echo -en "${YELLOW}? ${RESET}${prompt} ${DIM}[y/N]${RESET} "
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]]
}

# ─── Preflight Checks ──────────────────────────────────────────────────────────
check_prerequisites() {
    command -v git   >/dev/null 2>&1 || die "git is not installed"
    command -v mvn   >/dev/null 2>&1 || die "mvn is not installed"
    command -v xmllint >/dev/null 2>&1 || die "xmllint is not installed (try: apt install libxml2-utils)"
    [[ -d .git ]]       || die "Not a git repository"
    [[ -f pom.xml ]]    || die "No pom.xml found in current directory"

    # Check for uncommitted changes
    if ! git diff --quiet HEAD -- 2>/dev/null; then
        warn "You have uncommitted changes."
        if ! confirm "Continue anyway?"; then
            exit 0
        fi
    fi
}

# ─── Version Parsing ───────────────────────────────────────────────────────────
# Reads <version> from pom.xml (top-level project version only)
get_maven_version() {
    xmllint --xpath "/*[local-name()='project']/*[local-name()='version']/text()" pom.xml 2>/dev/null \
        || die "Could not read <version> from pom.xml"
}

# Strips -SNAPSHOT suffix if present
strip_snapshot() {
    echo "${1%-SNAPSHOT}"
}

# Returns 0 if version ends with -SNAPSHOT
is_snapshot() {
    [[ "$1" == *-SNAPSHOT ]]
}

# Split semver into parts; expects X.Y.Z (no v prefix)
parse_semver() {
    local ver="$1"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$ver"
    [[ "$MAJOR" =~ ^[0-9]+$ ]] || die "Invalid major version component: '$MAJOR' in '$ver'"
    [[ "$MINOR" =~ ^[0-9]+$ ]] || die "Invalid minor version component: '$MINOR' in '$ver'"
    [[ "$PATCH" =~ ^[0-9]+$ ]] || die "Invalid patch version component: '$PATCH' in '$ver'"
}

# ─── Version Bumping ───────────────────────────────────────────────────────────
bump_version() {
    local base_ver="$1" bump_type="$2"
    parse_semver "$base_ver"

    case "$bump_type" in
        patch) PATCH=$((PATCH + 1)) ;;
        minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
        major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
        *) die "Unknown bump type: $bump_type" ;;
    esac

    echo "${MAJOR}.${MINOR}.${PATCH}"
}

# ─── Maven Version Update ──────────────────────────────────────────────────────
set_maven_version() {
    local new_version="$1"
    info "Setting Maven version to ${BOLD}${new_version}${RESET}"
    mvn versions:set -DnewVersion="$new_version" -DgenerateBackupPoms=false -q \
        || die "mvn versions:set failed"
    ok "pom.xml updated"
}

# ─── Git Operations ────────────────────────────────────────────────────────────
create_tag() {
    local tag="$1" message="$2"
    info "Creating git tag ${BOLD}${tag}${RESET}"
    git tag -a "$tag" -m "$message"
    ok "Tag ${BOLD}${tag}${RESET} created on $(git rev-parse --short HEAD)"
}

delete_tag() {
    local tag="$1"
    if git rev-parse "$tag" >/dev/null 2>&1; then
        info "Deleting local tag ${BOLD}${tag}${RESET}"
        git tag -d "$tag"
        ok "Local tag deleted"

        # Also remove from remote if it exists there
        if git ls-remote --tags origin "$tag" 2>/dev/null | grep -q "$tag"; then
            if confirm "Tag ${tag} also exists on remote. Delete it?"; then
                git push origin ":refs/tags/$tag"
                ok "Remote tag deleted"
            fi
        fi
    else
        warn "Tag ${tag} does not exist locally"
    fi
}

commit_version_change() {
    local new_version="$1"
    git add pom.xml
    # Also stage any submodule pom.xml changes from versions:set
    git diff --name-only --cached | grep -q "pom.xml" || true
    find . -name "pom.xml" -not -path "./.git/*" -exec git add {} + 2>/dev/null || true
    git commit -m "release: set version to ${new_version}"
    ok "Version change committed"
}

# ─── Display Helpers ────────────────────────────────────────────────────────────
show_status() {
    local current_version="$1"
    local base_ver
    base_ver=$(strip_snapshot "$current_version")

    echo ""
    echo -e "${BOLD}┌──────────────────────────────────────┐${RESET}"
    echo -e "${BOLD}│         Release Manager              │${RESET}"
    echo -e "${BOLD}└──────────────────────────────────────┘${RESET}"
    echo ""
    echo -e "  Project version : ${BOLD}${current_version}${RESET}"
    echo -e "  Base version    : ${BOLD}${base_ver}${RESET}"
    echo -e "  Current commit  : ${DIM}$(git rev-parse --short HEAD)${RESET} $(git log -1 --format='%s' 2>/dev/null)"
    echo -e "  Branch          : ${CYAN}$(git branch --show-current 2>/dev/null || echo 'detached')${RESET}"

    # Show latest tags
    local latest_tags
    latest_tags=$(git tag --sort=-version:refname 2>/dev/null | head -5)
    if [[ -n "$latest_tags" ]]; then
        echo -e "  Recent tags     : ${DIM}$(echo "$latest_tags" | tr '\n' '  ' | sed 's/  $//')${RESET}"
    fi
    echo ""
}

show_menu() {
    local current_version="$1"
    local base_ver
    base_ver=$(strip_snapshot "$current_version")

    echo -e "${BOLD}  Choose a release action:${RESET}"
    echo ""

    # Option 0: re-tag snapshot — only show if current version is a snapshot and the tag exists
    if is_snapshot "$current_version"; then
        local snap_tag="v${current_version}"
        if git rev-parse "$snap_tag" >/dev/null 2>&1; then
            local tag_commit
            tag_commit=$(git rev-parse --short "$snap_tag")
            local head_commit
            head_commit=$(git rev-parse --short HEAD)
            echo -e "  ${BOLD}0)${RESET}  Re-tag snapshot      ${DIM}move ${snap_tag} (${tag_commit}) → current commit (${head_commit})${RESET}"
        else
            echo -e "  ${BOLD}0)${RESET}  Re-tag snapshot      ${DIM}(tag ${snap_tag} does not exist yet — use option 1 first)${RESET}"
        fi
    else
        echo -e "  ${DIM}0)  Re-tag snapshot      (current version is not a snapshot)${RESET}"
    fi

    echo -e "  ${BOLD}1)${RESET}  Snapshot release     ${DIM}→ v$(bump_version "$base_ver" patch)-SNAPSHOT${RESET}"
    echo -e "  ${BOLD}2)${RESET}  Patch release        ${DIM}→ v$(bump_version "$base_ver" patch)${RESET}"
    echo -e "  ${BOLD}3)${RESET}  Minor release        ${DIM}→ v$(bump_version "$base_ver" minor)${RESET}"
    echo -e "  ${BOLD}4)${RESET}  Major release        ${DIM}→ v$(bump_version "$base_ver" major)${RESET}"
    echo ""
    local default_cutoff
    default_cutoff=$(date -d "3 months ago" +%Y-%m-%d 2>/dev/null || date -v-3m +%Y-%m-%d 2>/dev/null || echo "???")
    echo -e "  ${BOLD}5)${RESET}  Clean up old tags    ${DIM}delete tags created before ${default_cutoff}${RESET}"
    echo ""
    echo -e "  ${DIM}q)  Quit${RESET}"
    echo ""
}

# ─── Release Actions ───────────────────────────────────────────────────────────

do_retag_snapshot() {
    local current_version="$1"

    if ! is_snapshot "$current_version"; then
        die "Current version is not a snapshot — nothing to re-tag."
    fi

    local snap_tag="v${current_version}"

    if ! git rev-parse "$snap_tag" >/dev/null 2>&1; then
        die "Tag ${snap_tag} does not exist. Do a snapshot release first (option 1)."
    fi

    local old_commit new_commit
    old_commit=$(git rev-parse --short "$snap_tag")
    new_commit=$(git rev-parse --short HEAD)

    if [[ "$(git rev-parse "$snap_tag")" == "$(git rev-parse HEAD)" ]]; then
        warn "Tag ${snap_tag} already points to the current commit (${new_commit}). Nothing to do."
        return 0
    fi

    echo ""
    echo -e "  ${BOLD}Re-tag Snapshot${RESET}"
    echo -e "  Tag      : ${BOLD}${snap_tag}${RESET}"
    echo -e "  Old commit : ${old_commit}"
    echo -e "  New commit : ${new_commit} $(git log -1 --format='%s')"
    echo ""

    if ! confirm "Move tag ${snap_tag} from ${old_commit} to ${new_commit}?"; then
        info "Aborted."
        return 0
    fi

    delete_tag "$snap_tag"
    create_tag "$snap_tag" "Snapshot release ${current_version} (re-tagged)"

    echo ""
    ok "Snapshot tag moved to current commit."
    offer_push "$snap_tag"
}

do_snapshot_release() {
    local current_version="$1"
    local base_ver
    base_ver=$(strip_snapshot "$current_version")

    local new_base
    new_base=$(bump_version "$base_ver" patch)
    local new_version="${new_base}-SNAPSHOT"
    local tag="v${new_version}"

    echo ""
    echo -e "  ${BOLD}Snapshot Release${RESET}"
    echo -e "  Current  : ${current_version}"
    echo -e "  New      : ${BOLD}${new_version}${RESET}"
    echo -e "  Tag      : ${BOLD}${tag}${RESET}"
    echo -e "  Commit   : $(git rev-parse --short HEAD)"
    echo ""

    if git rev-parse "$tag" >/dev/null 2>&1; then
        warn "Tag ${tag} already exists!"
        if ! confirm "Delete existing tag and re-create it?"; then
            info "Aborted."
            return 0
        fi
        delete_tag "$tag"
    fi

    if ! confirm "Proceed with snapshot release?"; then
        info "Aborted."
        return 0
    fi

    set_maven_version "$new_version"
    commit_version_change "$new_version"
    create_tag "$tag" "Snapshot release ${new_version}"

    echo ""
    ok "Snapshot release ${BOLD}${new_version}${RESET} complete!"
    offer_push "$tag"
}

do_release() {
    local current_version="$1" bump_type="$2"
    local base_ver
    base_ver=$(strip_snapshot "$current_version")

    local new_version
    new_version=$(bump_version "$base_ver" "$bump_type")
    local tag="v${new_version}"

    echo ""
    echo -e "  ${BOLD}${bump_type^} Release${RESET}"
    echo -e "  Current  : ${current_version}"
    echo -e "  New      : ${BOLD}${new_version}${RESET}"
    echo -e "  Tag      : ${BOLD}${tag}${RESET}"
    echo -e "  Commit   : $(git rev-parse --short HEAD)"
    echo ""

    if git rev-parse "$tag" >/dev/null 2>&1; then
        die "Tag ${tag} already exists. Delete it manually or choose a different version."
    fi

    if ! confirm "Proceed with ${bump_type} release?"; then
        info "Aborted."
        return 0
    fi

    set_maven_version "$new_version"
    commit_version_change "$new_version"
    create_tag "$tag" "Release ${new_version}"

    echo ""
    ok "Release ${BOLD}${new_version}${RESET} complete!"
    offer_push "$tag"
}

offer_push() {
    local tag="$1"
    echo ""
    if confirm "Push commit and tag to remote?"; then
        git push
        git push origin "$tag"
        ok "Pushed to remote."
    else
        info "Remember to push manually:"
        echo -e "  ${DIM}git push && git push origin ${tag}${RESET}"
    fi
}

# ─── Tag Cleanup ───────────────────────────────────────────────────────────────

do_cleanup_tags() {
    # Default cutoff: 3 months ago (GNU date with fallback to BSD/macOS date)
    local default_cutoff
    default_cutoff=$(date -d "3 months ago" +%Y-%m-%d 2>/dev/null || date -v-3m +%Y-%m-%d 2>/dev/null)

    echo ""
    echo -e "  ${BOLD}Tag Cleanup${RESET}"
    echo -e "  Delete all tags created before a cutoff date."
    echo ""
    echo -en "  ${BOLD}▸ ${RESET}Cutoff date ${DIM}[${default_cutoff}]${RESET}: "
    read -r input_date

    local cutoff="${input_date:-$default_cutoff}"

    # Validate date format
    if ! date -d "$cutoff" +%s >/dev/null 2>&1 && ! date -j -f "%Y-%m-%d" "$cutoff" +%s >/dev/null 2>&1; then
        die "Invalid date: '$cutoff'. Use YYYY-MM-DD format."
    fi

    local cutoff_epoch
    cutoff_epoch=$(date -d "$cutoff" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$cutoff" +%s 2>/dev/null)

    info "Finding tags created before ${BOLD}${cutoff}${RESET} ..."
    echo ""

    local old_tags=()
    local tag_details=()

    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue

        # Get the tagger date for annotated tags, or committer date for lightweight tags
        local tag_date_raw
        tag_date_raw=$(git for-each-ref "refs/tags/$tag" --format='%(creatordate:iso)' 2>/dev/null)

        if [[ -z "$tag_date_raw" ]]; then
            continue
        fi

        local tag_epoch
        tag_epoch=$(date -d "$tag_date_raw" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S %z" "$tag_date_raw" +%s 2>/dev/null || echo "0")

        if (( tag_epoch < cutoff_epoch )); then
            local tag_date_short
            tag_date_short=$(date -d "$tag_date_raw" +%Y-%m-%d 2>/dev/null || echo "${tag_date_raw:0:10}")
            old_tags+=("$tag")
            tag_details+=("$tag_date_short")
        fi
    done < <(git tag --sort=version:refname)

    if [[ ${#old_tags[@]} -eq 0 ]]; then
        ok "No tags found before ${cutoff}. Nothing to clean up."
        return 0
    fi

    echo -e "  ${BOLD}Tags to delete (${#old_tags[@]}):${RESET}"
    echo ""
    for i in "${!old_tags[@]}"; do
        echo -e "    ${RED}✖${RESET} ${old_tags[$i]}  ${DIM}(${tag_details[$i]})${RESET}"
    done
    echo ""

    if ! confirm "Delete these ${#old_tags[@]} tags locally?"; then
        info "Aborted."
        return 0
    fi

    for tag in "${old_tags[@]}"; do
        git tag -d "$tag" >/dev/null 2>&1
    done
    ok "Deleted ${#old_tags[@]} local tags."

    # Check remote
    echo ""
    local remote_tags=()
    info "Checking which of these exist on remote ..."
    for tag in "${old_tags[@]}"; do
        if git ls-remote --tags origin "$tag" 2>/dev/null | grep -q "$tag"; then
            remote_tags+=("$tag")
        fi
    done

    if [[ ${#remote_tags[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}${#remote_tags[@]} of these also exist on remote.${RESET}"
        if confirm "Delete them from remote too?"; then
            local refs=()
            for tag in "${remote_tags[@]}"; do
                refs+=(":refs/tags/$tag")
            done
            git push origin "${refs[@]}"
            ok "Deleted ${#remote_tags[@]} remote tags."
        else
            info "Remote tags left untouched."
        fi
    else
        info "None of the deleted tags exist on remote."
    fi
}

# ─── Dry-run support ───────────────────────────────────────────────────────────
DRY_RUN=false
if [[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]]; then
    DRY_RUN=true
    warn "DRY-RUN mode — no changes will be made."
    echo ""
fi

# ─── Main ──────────────────────────────────────────────────────────────────────
main() {
    check_prerequisites

    local current_version
    current_version=$(get_maven_version)

    show_status "$current_version"
    show_menu "$current_version"

    echo -en "${BOLD}  ▸ ${RESET}Enter choice: "
    read -r choice

    case "$choice" in
        0) do_retag_snapshot "$current_version" ;;
        1) do_snapshot_release "$current_version" ;;
        2) do_release "$current_version" "patch" ;;
        3) do_release "$current_version" "minor" ;;
        4) do_release "$current_version" "major" ;;
        5) do_cleanup_tags ;;
        q|Q) echo ""; info "Bye."; exit 0 ;;
        *) die "Invalid choice: $choice" ;;
    esac
}

main
