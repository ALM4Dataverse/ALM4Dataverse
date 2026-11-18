#!/bin/sh
# Provides the Dev Container mount in devcontainer.json with the Git common
# directory of this checkout, including when the checkout is a linked worktree.
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
workspace=$(dirname -- "$script_dir")
link=$script_dir/git-common

# Git for Windows can run this file through its POSIX shell. A Windows link
# target is not usable in the container, so leave a plain directory there.
case "$(uname -s 2>/dev/null || true)" in
    MINGW*|MSYS*|CYGWIN*)
        if [ -L "$link" ]; then
            rm -f "$link"
        fi
        if [ ! -d "$link" ]; then
            mkdir -p "$link"
        fi
        exit 0
        ;;
esac

common=$(git -C "$workspace" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
if [ -z "$common" ]; then
    # --path-format is unavailable before Git 2.31.
    common=$(git -C "$workspace" rev-parse --git-common-dir 2>/dev/null || true)
fi

if [ -z "$common" ]; then
    # Not a Git checkout: the static mount still needs an existing source.
    common=${TMPDIR:-/tmp}/alm4dataverse-devcontainer-git-common
    mkdir -p "$common"
else
    case "$common" in
        /*) ;;
        *) common=$(CDPATH= cd -- "$workspace/$common" && pwd) ;;
    esac
fi

if [ ! -d "$common" ]; then
    echo "Git common directory does not exist: $common" >&2
    exit 1
fi

if [ -L "$link" ]; then
    rm -f "$link"
elif [ -e "$link" ]; then
    # A directory may be the Windows placeholder; only remove it when empty.
    rmdir "$link" 2>/dev/null || {
        echo "Refusing to replace $link; remove it and restart the container." >&2
        exit 1
    }
fi

ln -s "$common" "$link"
