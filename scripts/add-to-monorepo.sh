#!/usr/bin/env bash

set -e

### Command-line arguments ###

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 repo_name"
    echo "Example: $0 scratch-foo"
    echo ""
    echo "This script will add the specified repository to the current branch of the monorepo in the current directory."
    exit 1
fi

SRC_REPO="$1"

### Configuration ###

# All repositories are assumed to be hosted in this GitHub org
GITHUB_ORG="scratchfoundation"

# All packages are assumed to be published under this npm organization
NPM_ORGANIZATION="@scratch"

# This is the directory where you have a copy of all the repositories you want to merge.
# This script will run `git fetch` on these repos, but otherwise will not modify them.
BUILD_CACHE="./.."

# Temporary clones will be placed here. If the script completes successfully, this directory will be deleted.
BUILD_TMP="./monorepo.tmp"

# Use ${BASE_COMMIT} from ${BASE_REPO} as the starting point for the monorepo.
BASE_COMMIT="$(git rev-parse HEAD)"

# Limit the threads and memory used by git repack & git gc. This script only uses these values in final optimization.
# If you see "error: pack-objects died of signal 9" or an out-of-memory error, try reducing one or both.
# In my experiments, the maximum memory used was around 2.2 * GIT_PACK_THREADS * GIT_PACK_WINDOW_MEMORY.
# Values above 512m did not seem to improve compression in my tests. The cutoff is somewhere between 256m and 512m.
# See git documentation for pack.threads and pack.windowMemory for more information.
# Increasing threads speeds up the operation, but uses more CPU and memory.
# Increasing windowMemory may compress the .git directory better, but takes more time and uses more memory.
# Setting threads to zero will tell git to detect your CPU count.
# Setting window memory to zero will remove the limit.
# WARNING: on some configurations, window memory is stored in a signed 32-bit integer, so the maximum value is ~2047m.
GIT_PACK_THREADS="8"
GIT_PACK_WINDOW_MEMORY="512m"

# Options to speed up `npm install` during the fixup phase
NPM_QUICK_OPTS="--prefer-offline --no-audit --no-fund"

### End configuration ###

### Functions ###

# Thanks to https://stackoverflow.com/a/17841619
join_args () {
    local d=${1-} f=${2-}
    if shift 2; then
        printf %s "$f" "${@/#/$d}"
    fi
}

add_repo_to_monorepo () {
    REPO_NAME="$1"
    ORG_AND_REPO_NAME="${GITHUB_ORG}/${REPO_NAME}"
    echo "Working on $ORG_AND_REPO_NAME"

    clone_repository $REPO_NAME

    move_repository_subdirectory $REPO_NAME "packages/${REPO_NAME}"

    #
    # Merge branches in
    #

    REMOTE_NAME="temp-$REPO_NAME"
    git remote add "$REMOTE_NAME" "$(realpath "${BUILD_TMP}")/${REPO_NAME}"
    git fetch --no-tags "$REMOTE_NAME"

    SRC_BRANCH="$(default_branch)"

    MERGE_MESSAGE="feat(deps): add ${REPO_NAME}#${SRC_BRANCH} as packages/${REPO_NAME}"
    git merge --no-ff --allow-unrelated-histories "${REMOTE_NAME}/${SRC_BRANCH}" -m "$MERGE_MESSAGE"

    git remote remove "$REMOTE_NAME"
    rm -rf "${BUILD_TMP}/${REPO_NAME}"
}

clone_repository() {
    REPO_NAME="$1"
    ORG_AND_REPO_NAME="${GITHUB_ORG}/${REPO_NAME}"

    #
    # Clone
    #

    # refresh the cache
    git -C "${BUILD_CACHE}/${REPO_NAME}" fetch --all
    # reference = go faster
    git -C "$BUILD_TMP" clone --bare --dissociate --reference "$(realpath "$BUILD_CACHE")/${REPO_NAME}" "git@github.com:${ORG_AND_REPO_NAME}.git" "${REPO_NAME}"
    # get ready to disconnect reference repo
    git -C "${BUILD_TMP}/${REPO_NAME}" repack -a
    # actually disconnect the reference repo
    rm -f "${BUILD_TMP}/${REPO_NAME}/.git/objects/info/alternates"
}

move_repository_subdirectory() {
    REPO_NAME="$1"
    SUBDIRECTORY="$2"

    #
    # Move to subdirectory
    #

    # make filter-repo accept this as a fresh clone
    git -C "${BUILD_TMP}/${REPO_NAME}" gc

    HAS_SUBMODULES=$(
        git -C "${BUILD_TMP}/${REPO_NAME}" branch --format="%(refname:short)" | while read BRANCH; do
            if git -C "${BUILD_TMP}/${REPO_NAME}" cat-file -e "${BRANCH}:.gitmodules" &> /dev/null; then
                echo "yep"
                break;
            fi
        done
    )

    # rewrite history as if all this work happened in a subdirectory
    # "git mv" is simpler but makes history much less visible
    if [ "$HAS_SUBMODULES" != "yep" ]; then
        echo "Repository ${REPO_NAME} does NOT have submodules"
        # this is significantly faster than the special case below
        git -C "${BUILD_TMP}/${REPO_NAME}" filter-repo --to-subdirectory-filter $SUBDIRECTORY
    else
        echo "Repository ${REPO_NAME} DOES have submodules"
        # the .gitmodules file must stay in the repository root, but the paths inside it must be rewritten
        # this is complicated for the reasons described here: https://github.com/newren/git-filter-repo/issues/158
        # this is also slower, so we only do it for repositories that have submodules
        # if we have more than one, this will cause merge conflicts
        git -C "${BUILD_TMP}/${REPO_NAME}" filter-repo \
            --filename-callback "return filename if filename == b'.gitmodules' else b'${SUBDIRECTORY}'+filename" \
            --blob-callback "if blob.data.startswith(b'[submodule '): blob.data = blob.data.replace(b'path = ', b'path = ${SUBDIRECTORY}')"
    fi
}

default_branch () {
    BRANCH="develop"

    if [ -z "$(git -C "${BUILD_TMP}/${REPO_NAME}" branch --list "$BRANCH")" ]; then
        BRANCH="main"

        if [ -z "$(git -C "${BUILD_TMP}/${REPO_NAME}" branch --list "$BRANCH")" ]; then
            BRANCH="master"
        fi
    fi

    echo "$BRANCH"
}

# Perform monorepo fixups on a package.
# Mostly: remove "global" files from subdirectories and localize dependencies.
#   $1: the name of the package to fix up
fixup_package () {
    PACKAGE="$1"

    if [ ! -r "./packages/"$PACKAGE"/package.json" ]; then
        # This repository doesn't exist in this branch
        echo "Warning: Package $PACKAGE does not exist in this branch"
        return
    fi

    # remove repository-level configuration and dependencies, like Renovate and Husky
    # do not remove configuration and dependencies that could vary between packages, like semantic-release
    # do not remove content like .github/ that may be useful as reference when building the monorepo equivalent
    # it would be nice to merge all the package-lock.json files into one but it's not clear how to do that
    # just remove the package-lock.json files for now, and build a new one with "npm i" later
    rm -rf ./packages/"$PACKAGE"/{.husky,package-lock.json,renovate.json*}

    jq -f \
        --arg PACKAGE_NAME "$NPM_ORGANIZATION/$PACKAGE" \
        --arg MONOREPO_AUTHOR "$MONOREPO_AUTHOR" \
        --arg MONOREPO_LICENSE "$MONOREPO_LICENSE" \
        --arg MONOREPO_VERSION "$MONOREPO_VERSION" \
        <(join_args ' | ' \
            '.name |= $PACKAGE_NAME' \
            '.version |= $MONOREPO_VERSION' \
            'del(.repository.sha)' \
            '.license |= $MONOREPO_LICENSE' \
            '.author |= $MONOREPO_AUTHOR' \
            'if .scripts.prepare == "husky install" then del(.scripts.prepare) else . end' \
            'if .scripts == {} then del(.scripts.prepare) else . end' \
            'del(.config.commitizen)' \
            'if .config == {} then del(.config) else . end' \
            'del(.devDependencies."@commitlint/cli")' \
            'del(.devDependencies."@commitlint/config-conventional")' \
            'del(.devDependencies."@commitlint/travis-cli")' \
            'del(.devDependencies."cz-conventional-changelog")' \
            'del(.devDependencies."husky")' \
            'if .devDependencies == {} then del(.devDependencies) else . end' \
        ) "./packages/${PACKAGE}/package.json" | sponge "./packages/${PACKAGE}/package.json"

    npm init -y -w "./packages/${PACKAGE}"
    sort-package-json "./packages/${PACKAGE}/package.json"
    npm i --package-lock-only # sometimes this is necessary to get a consistent package-lock.json
    git add package.json package-lock.json "./packages/${PACKAGE}/"

    git commit -m "fix: update ${PACKAGE} name, deps, etc., for monorepo"
}

# Replace any dependencies that are within the monorepo with their monorepo version
fixup_deps () {
    PACKAGE_DIR="$1"

    echo "Fixing up dependencies for $PACKAGE_DIR"
    echo "Possible dependencies: ${ALL_PACKAGE_NAMES[@]}"

    REMOVEDEPS=""
    DEPS=""
    DEVDEPS=""
    OPTDEPS=""
    PEERDEPS=""
    for DEP in "${ALL_PACKAGE_NAMES[@]}"; do
        if jq -e .dependencies.\"$DEP\" "./packages/${PACKAGE_DIR}/package.json" > /dev/null; then
            jq  "del(.dependencies.\"$DEP\")" "./packages/${PACKAGE_DIR}/package.json" | sponge "./packages/${PACKAGE_DIR}/package.json"
            DEPS="$DEPS $DEP@*"
        fi
        if jq -e .devDependencies.\"$DEP\" "./packages/${PACKAGE_DIR}/package.json" > /dev/null; then
            jq  "del(.devDependencies.\"$DEP\")" "./packages/${PACKAGE_DIR}/package.json" | sponge "./packages/${PACKAGE_DIR}/package.json"
            DEVDEPS="$DEVDEPS $DEP@*"
        fi
        if jq -e .optionalDependencies.\"$DEP\" "./packages/${PACKAGE_DIR}/package.json" > /dev/null; then
            jq  "del(.optionalDependencies.\"$DEP\")" "./packages/${PACKAGE_DIR}/package.json" | sponge "./packages/${PACKAGE_DIR}/package.json"
            OPTDEPS="$OPTDEPS $DEP@*"
        fi
        if jq -e .peerDependencies.\"$DEP\" "./packages/${PACKAGE_DIR}/package.json" > /dev/null; then
            jq  "del(.peerDependencies.\"$DEP\")" "./packages/${PACKAGE_DIR}/package.json" | sponge "./packages/${PACKAGE_DIR}/package.json"
            PEERDEPS="$PEERDEPS $DEP@*"
        fi

        npm uninstall "$DEP"
    done
    for DEP in $DEPS; do
        npm install --force --save --save-exact "$NPM_ORGANIZATION/$DEP" -w "$NPM_ORGANIZATION/$PACKAGE_DIR" || package_replacement_error "$PACKAGE_DIR" "$DEP"
    done
    for DEP in $DEVDEPS; do
        npm install --force --save-dev --save-exact "$NPM_ORGANIZATION/$DEP" -w "$NPM_ORGANIZATION/$PACKAGE_DIR" || package_replacement_error "$PACKAGE_DIR" "$DEP"
    done
    for DEP in $OPTDEPS; do
        npm install --force --save-optional --save-exact "$NPM_ORGANIZATION/$DEP" -w "$NPM_ORGANIZATION/$PACKAGE_DIR" || package_replacement_error "$PACKAGE_DIR" "$DEP"
    done
    for DEP in $PEERDEPS; do
        npm install --force --save-peer --save-exact "$NPM_ORGANIZATION/$DEP" -w "$NPM_ORGANIZATION/$PACKAGE_DIR" || package_replacement_error "$PACKAGE_DIR" "$DEP"
    done

    # replace the name of the package with the organization prefixed one
    for DEP in "${ALL_PACKAGE_NAMES[@]}"; do
        find "./packages/${PACKAGE_DIR}" -type f -exec sed -i -e "s:\(require(\|from\s\|resolve(\|node_modules\)\(['\"/]\)$DEP\(['\"/]\):\1\2$NPM_ORGANIZATION/$DEP\3:g" {} \;
    done

    sort-package-json "./packages/${PACKAGE_DIR}/package.json"
}

# Report that replacing a dependency with the local monorepo version failed
# $1: the name of the repository
# $2: the dependency that failed to install
package_replacement_error () {
    echo "***ERROR***"
    echo "Could not replace a dependency with the local monorepo version."
    echo "Failed to replace $2 in $1" | tee -a "monorepo.errors.log"
    #exit 1 # uncomment this to make it a fatal error
    echo "Attempting to continue anyway..."
}

### Pre-flight checks ###

if ! git filter-repo -h &> /dev/null; then
    echo "Please install git-filter-repo. One of these commands might work:"
    echo "- brew install git-filter-repo"
    echo "- sudo apt install git-filter-repo"
    exit 1
fi

if ! sponge --help &> /dev/null; then
    echo "Please install the 'sponge' command."
    echo "You may want: sudo apt install moreutils"
    exit 1
fi

if [ ! -d "$BUILD_CACHE" ]; then
    echo "Please link $BUILD_CACHE to a directory with a copy of all the repositories you want to merge."
    echo "For example, if you have ~/GitHub/scratch-audio, ~/GitHub/scratch-blocks, etc., then run:"
    echo "ln -s ~/GitHub $BUILD_CACHE"
    exit 1
fi

if [ -d "$BUILD_TMP" ]; then
    echo "Please remove $BUILD_TMP before running this script."
    echo "You may want: rm -rf $BUILD_TMP"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "Please commit or stash your changes before running this script."
    exit 1
fi

### Do the things! ###

echo "This may take a long time! Make sure you have plenty of space on your drive."
echo "Press Ctrl-C now to cancel!"
echo "Starting in 15 seconds..."
sleep 15

mkdir -p "$BUILD_TMP"

set -x

MONOREPO_AUTHOR="$(jq -r .author "./package.json")"
MONOREPO_LICENSE="$(jq -r .license "./package.json")"
MONOREPO_VERSION="$(jq -r .version "./package.json")"

add_repo_to_monorepo "$SRC_REPO"

rmdir "$BUILD_TMP"

# Collect package dirs/names AFTER adding the new repo
# Note that the package names do NOT include the organization prefix
mapfile -t ALL_PACKAGE_DIRS < <(cd packages/ && for P in */package.json; do echo "${P%/*}"; done)
mapfile -t ALL_PACKAGE_NAMES < <(for P in "${ALL_PACKAGE_DIRS[@]}"; do node -p "require('./packages/$P/package.json').name.replace('$NPM_ORGANIZATION/', '')"; done)

echo "ALL_PACKAGE_DIRS: ${ALL_PACKAGE_DIRS[@]}"
echo "ALL_PACKAGE_NAMES: ${ALL_PACKAGE_NAMES[@]}"

fixup_package "$SRC_REPO"

for PKG_DIR in "${ALL_PACKAGE_DIRS[@]}"; do
    fixup_deps "$PKG_DIR"
done
npm i --package-lock-only
npm i --package-lock-only
git add .
git commit -m "fix(deps): use workspace versions of $SRC_REPO and other packages"

cat <<EOF

All done! Manual followup steps:
- Check that the new workspace's position (build order) in the package.json 'workspaces' list is correct
- Verify that all references to the old repo are replaced with new monorepo references
- Run 'npm ci' and fix any dependency issues
- Run 'npm run build' and fix any build issues
- Run 'npm run test' and fix any test issues
- Fix up any CI/CD workflows
- Add the repo to ALL_REPOS in this script

You may want to repack your copy of the repo to save space with something like:
  du -sh && git gc -c pack.threads=8 -c pack.windowMemory=512m --aggressive --prune='5 minutes ago' && du -sh
Replace the thread count and window memory according to your system's capabilities.
This does not affect the remote repository, so you can skip this step if local size is not a major concern.
EOF
