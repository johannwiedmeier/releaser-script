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
    command -v git >/dev/null 2>&1 || die "git is not installed"
    [[ -d .git ]] || die "Not a git repository"
 
    if ! git diff --quiet HEAD -- 2>/dev/null; then
        warn "You have uncommitted changes."
        if ! confirm "Continue anyway?"; then
            exit 0
        fi
    fi
}
 
# ─── Version from Tags ─────────────────────────────────────────────────────────
# Finds the latest semver tag reachable from HEAD, sorted numerically.
# Supports v1.2.3, v1.2.3-SNAPSHOT, 1.2.3, 1.2.3-SNAPSHOT
get_latest_version() {
    local latest
    latest=$(
        git tag --merged HEAD 2>/dev/null \
        | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+(-SNAPSHOT)?$' \
        | sed 's/^v//' \
        | sort -t. -k1,1n -k2,2n -k3,3n \
        | tail -1
    )
    echo "${latest:-0.0.0}"
}
 
strip_snapshot() {
    echo "${1%-SNAPSHOT}"
}
 
is_snapshot() {
    [[ "$1" == *-SNAPSHOT ]]
}
 
parse_semver() {
    local ver="$1"
    IFS='.' read -r MAJOR MINOR PATCH <<< "$ver"
    [[ "$MAJOR" =~ ^[0-9]+$ ]] || die "Invalid major version: '$MAJOR' in '$ver'"
    [[ "$MINOR" =~ ^[0-9]+$ ]] || die "Invalid minor version: '$MINOR' in '$ver'"
    [[ "$PATCH" =~ ^[0-9]+$ ]] || die "Invalid patch version: '$PATCH' in '$ver'"
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
 
# Bumps version, then keeps incrementing patch if the resulting tag already exists.
# For snapshot=true, checks vX.Y.Z-SNAPSHOT; for snapshot=false, checks vX.Y.Z.
next_available_version() {
    local base_ver="$1" bump_type="$2" snapshot="${3:-false}"
    local candidate
    candidate=$(bump_version "$base_ver" "$bump_type")
 
    local tag_to_check
    if [[ "$snapshot" == "true" ]]; then
        tag_to_check="v${candidate}-SNAPSHOT"
    else
        tag_to_check="v${candidate}"
    fi
 
    while git rev-parse "$tag_to_check" >/dev/null 2>&1; do
        candidate=$(bump_version "$candidate" patch)
        if [[ "$snapshot" == "true" ]]; then
            tag_to_check="v${candidate}-SNAPSHOT"
        else
            tag_to_check="v${candidate}"
        fi
    done
 
    echo "$candidate"
}
 
# ─── Git Operations ────────────────────────────────────────────────────────────
create_tag() {
    local tag="$1" message="$2"
    info "Creating git tag ${BOLD}${tag}${RESET}"
    git tag -s "$tag" -m "$message"
    ok "Tag ${BOLD}${tag}${RESET} created on $(git rev-parse --short HEAD)"
}
 
delete_tag_local_and_remote() {
    local tag="$1"
    if git rev-parse "$tag" >/dev/null 2>&1; then
        git tag -d "$tag" >/dev/null 2>&1
        ok "Local tag ${BOLD}${tag}${RESET} deleted"
    fi
 
    if git ls-remote --tags origin "$tag" 2>/dev/null | grep -q "$tag"; then
        if confirm "Tag ${tag} also exists on remote. Delete it?"; then
            git push origin ":refs/tags/$tag"
            ok "Remote tag deleted"
        fi
    fi
}
 
offer_push() {
    local tag="$1"
    echo ""
    if confirm "Push tag to remote?"; then
        git push origin "$tag"
        ok "Pushed tag to remote."
    else
        info "Remember to push manually:"
        echo -e "  ${DIM}git push origin ${tag}${RESET}"
    fi
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
    echo -e "  Latest version  : ${BOLD}${current_version}${RESET}"
    echo -e "  Base version    : ${BOLD}${base_ver}${RESET}"
    echo -e "  Current commit  : ${DIM}$(git rev-parse --short HEAD)${RESET} $(git log -1 --format='%s' 2>/dev/null)"
    echo -e "  Branch          : ${CYAN}$(git branch --show-current 2>/dev/null || echo 'detached')${RESET}"
 
    local latest_tags
    latest_tags=$(git tag --merged HEAD --sort=-version:refname 2>/dev/null | head -5)
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
    echo -e "  ${BOLD}0)${RESET}  Re-tag              ${DIM}move an existing tag to the current commit${RESET}"
    echo -e "  ${BOLD}1)${RESET}  Snapshot release     ${DIM}→ v$(next_available_version "$base_ver" patch true)-SNAPSHOT${RESET}"
    echo -e "  ${BOLD}2)${RESET}  Patch release        ${DIM}→ v$(next_available_version "$base_ver" patch)${RESET}"
    echo -e "  ${BOLD}3)${RESET}  Minor release        ${DIM}→ v$(next_available_version "$base_ver" minor)${RESET}"
    echo -e "  ${BOLD}4)${RESET}  Major release        ${DIM}→ v$(next_available_version "$base_ver" major)${RESET}"
    echo ""
    echo -e "  ${DIM}q)  Quit${RESET}"
    echo ""
}
 
# ─── Release Actions ───────────────────────────────────────────────────────────
 
do_retag() {
    local branch
    branch=$(git branch --show-current 2>/dev/null || echo "")
 
    if [[ "$branch" == "main" || "$branch" == "master" ]]; then
        die "Re-tagging is not available on ${branch}."
    fi
 
    # Find tags from the last 4 weeks that are NOT on main/master
    local cutoff_epoch
    cutoff_epoch=$(date -d "4 weeks ago" +%s 2>/dev/null || date -v-4w +%s 2>/dev/null)
 
    local default_branch=""
    if git rev-parse --verify main >/dev/null 2>&1; then
        default_branch="main"
    elif git rev-parse --verify master >/dev/null 2>&1; then
        default_branch="master"
    fi
 
    local candidates=()
    local candidate_dates=()
    local candidate_commits=()
 
    while IFS= read -r tag; do
        [[ -z "$tag" ]] && continue
 
        # Skip tags that are on the default branch
        if [[ -n "$default_branch" ]] && git merge-base --is-ancestor "$tag" "$default_branch" 2>/dev/null; then
            continue
        fi
 
        local tag_date_raw
        tag_date_raw=$(git for-each-ref "refs/tags/$tag" --format='%(creatordate:iso)' 2>/dev/null)
        [[ -z "$tag_date_raw" ]] && continue
 
        local tag_epoch
        tag_epoch=$(date -d "$tag_date_raw" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M:%S %z" "$tag_date_raw" +%s 2>/dev/null || echo "0")
 
        if (( tag_epoch >= cutoff_epoch )); then
            local tag_date_short
            tag_date_short=$(date -d "$tag_date_raw" +%Y-%m-%d 2>/dev/null || echo "${tag_date_raw:0:10}")
            local tag_commit
            tag_commit=$(git rev-parse --short "$tag" 2>/dev/null)
            candidates+=("$tag")
            candidate_dates+=("$tag_date_short")
            candidate_commits+=("$tag_commit")
        fi
    done < <(git tag --sort=-version:refname 2>/dev/null)
 
    if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No eligible tags found (not on ${default_branch:-main}, last 4 weeks)."
        return 0
    fi
 
    local head_commit
    head_commit=$(git rev-parse --short HEAD)
 
    echo ""
    echo -e "  ${BOLD}Select a tag to move to current commit (${head_commit}):${RESET}"
    echo ""
    for i in "${!candidates[@]}"; do
        local marker=""
        if [[ "${candidate_commits[$i]}" == "$head_commit" ]]; then
            marker=" ${DIM}(already on HEAD)${RESET}"
        fi
        echo -e "    ${BOLD}$((i + 1)))${RESET}  ${candidates[$i]}  ${DIM}(${candidate_dates[$i]} @ ${candidate_commits[$i]})${RESET}${marker}"
    done
    echo ""
    echo -e "    ${DIM}q)  Cancel${RESET}"
    echo ""
 
    echo -en "  ${BOLD}▸ ${RESET}Enter choice: "
    read -r pick
 
    [[ "$pick" == "q" || "$pick" == "Q" ]] && { info "Cancelled."; return 0; }
    [[ "$pick" =~ ^[0-9]+$ ]] || die "Invalid choice."
 
    local idx=$((pick - 1))
    (( idx >= 0 && idx < ${#candidates[@]} )) || die "Out of range."
 
    local selected_tag="${candidates[$idx]}"
    local old_commit="${candidate_commits[$idx]}"
 
    if [[ "$old_commit" == "$head_commit" ]]; then
        warn "Tag ${selected_tag} already points to current commit. Nothing to do."
        return 0
    fi
 
    echo ""
    echo -e "  ${BOLD}Re-tag${RESET}"
    echo -e "  Tag        : ${BOLD}${selected_tag}${RESET}"
    echo -e "  Old commit : ${old_commit}"
    echo -e "  New commit : ${head_commit} $(git log -1 --format='%s')"
    echo ""
 
    if ! confirm "Move tag ${selected_tag} to current commit?"; then
        info "Aborted."
        return 0
    fi
 
    delete_tag_local_and_remote "$selected_tag"
    create_tag "$selected_tag" "Re-tagged ${selected_tag}"
 
    echo ""
    ok "Tag ${BOLD}${selected_tag}${RESET} moved to current commit."
    offer_push "$selected_tag"
}
 
do_snapshot_release() {
    local current_version="$1"
    local base_ver
    base_ver=$(strip_snapshot "$current_version")
 
    local new_base
    new_base=$(next_available_version "$base_ver" patch true)
    local new_version="${new_base}-SNAPSHOT"
    local tag="v${new_version}"
 
    echo ""
    echo -e "  ${BOLD}Snapshot Release${RESET}"
    echo -e "  Current  : ${current_version}"
    echo -e "  New      : ${BOLD}${new_version}${RESET}"
    echo -e "  Tag      : ${BOLD}${tag}${RESET}"
    echo -e "  Commit   : $(git rev-parse --short HEAD)"
    echo ""
 
    if ! confirm "Proceed with snapshot release?"; then
        info "Aborted."
        return 0
    fi
 
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
    new_version=$(next_available_version "$base_ver" "$bump_type")
    local tag="v${new_version}"
 
    echo ""
    echo -e "  ${BOLD}${bump_type^} Release${RESET}"
    echo -e "  Current  : ${current_version}"
    echo -e "  New      : ${BOLD}${new_version}${RESET}"
    echo -e "  Tag      : ${BOLD}${tag}${RESET}"
    echo -e "  Commit   : $(git rev-parse --short HEAD)"
    echo ""
 
    if ! confirm "Proceed with ${bump_type} release?"; then
        info "Aborted."
        return 0
    fi
 
    create_tag "$tag" "Release ${new_version}"
 
    echo ""
    ok "Release ${BOLD}${new_version}${RESET} complete!"
    offer_push "$tag"
}
 
# ─── Main ──────────────────────────────────────────────────────────────────────
main() {
    check_prerequisites
 
    local current_version
    current_version=$(get_latest_version)
 
    show_status "$current_version"
    show_menu "$current_version"
 
    echo -en "${BOLD}  ▸ ${RESET}Enter choice: "
    read -r choice
 
    case "$choice" in
        0) do_retag ;;
        1) do_snapshot_release "$current_version" ;;
        2) do_release "$current_version" "patch" ;;
        3) do_release "$current_version" "minor" ;;
        4) do_release "$current_version" "major" ;;
        q|Q) echo ""; info "Bye."; exit 0 ;;
        *) die "Invalid choice: $choice" ;;
    esac
}
 
main
 
