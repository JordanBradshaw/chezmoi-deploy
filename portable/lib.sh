# Shim for build.sh and build-tools.sh: finds the chezmoi tree (which owns
# apps/) and sources its apps/lib.sh for the shared functions.

# resolve_chezmoi_src [DIR]: set and export CHEZMOI_SRC from DIR, $CHEZMOI_SRC
# or `chezmoi source-path` (in that order), then source its apps/lib.sh.
resolve_chezmoi_src() {
    local dir=${1:-${CHEZMOI_SRC:-}} sp
    if [[ -z $dir ]] && command -v chezmoi >/dev/null 2>&1; then
        sp="$(chezmoi source-path 2>/dev/null)" || sp=
        [[ -n $sp ]] && dir="$(git -C "$sp" rev-parse --show-toplevel 2>/dev/null)"
    fi
    if [[ -z $dir ]]; then
        echo "no chezmoi tree found (set CHEZMOI_SRC or --chezmoi to a chezmoi checkout)" >&2
        return 1
    fi
    if [[ ! -f $dir/apps/apps.tsv ]]; then
        echo "no apps/apps.tsv in $dir (set CHEZMOI_SRC or --chezmoi to a chezmoi checkout)" >&2
        return 1
    fi
    CHEZMOI_SRC="$(cd "$dir" && pwd)"
    export CHEZMOI_SRC
    APPS_FILE="$CHEZMOI_SRC/apps/apps.tsv"
    # shellcheck source=/dev/null
    source "$CHEZMOI_SRC/apps/lib.sh"
}
