#!/usr/bin/env bash
#
# Tests for scripts/portable/build.sh and zssh.
#
# build.sh is sourced for its helper functions. zssh runs against a stub ssh
# that executes remote commands locally with HOME pointing into a sandbox,
# and a stub builder that produces a tiny fake bundle, so nothing touches the
# network or a real host.
#
# PORTABLE_E2E=1 also builds real bundles and runs them in offline
# containers (needs network for the build, and docker). PORTABLE_E2E_ARCHES
# picks targets: "x86_64 aarch64 armv7l qos" (default x86_64); qos runs the
# aarch64 bundle against the Jetson Yocto SDK sysroot in $QOS_IMAGE.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$REPO_DIR/scripts/portable/build.sh"
ZSSH="$REPO_DIR/home/dot_local/bin/executable_zssh"

PASS=0
FAIL=0

# shellcheck source=../scripts/portable/build.sh
source "$BUILD"

# ---------------------------------------------------------------------------
# Sandbox helpers
# ---------------------------------------------------------------------------

setup() {
    SANDBOX="$(mktemp -d)"
    STUBS="$SANDBOX/stubs"
    export REMOTE_HOME="$SANDBOX/remote-home"
    export STUB_LOG="$SANDBOX/calls.log"
    export DIST="$SANDBOX/dist"
    export REMOTE_ARCH=aarch64
    export FAKE_VERSION=v1
    unset REMOTE_PATH_ONLY
    mkdir -p "$STUBS" "$REMOTE_HOME" "$DIST"
    : >"$STUB_LOG"
    OUTPUT=""
    STATUS=0
}

teardown() {
    rm -rf "$SANDBOX"
}

# stub_remote: fake ssh and builder for zssh.
stub_remote() {
    # Remote commands see this uname.
    mkdir -p "$SANDBOX/remote-bin"
    cat >"$SANDBOX/remote-bin/uname" <<'EOF'
#!/bin/sh
echo "$REMOTE_ARCH"
EOF
    chmod +x "$SANDBOX/remote-bin/uname"

    cat >"$STUBS/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >>"$STUB_LOG"
args=("$@")
i=0
while (( i < ${#args[@]} )); do
    case ${args[i]} in
        -[oipJlFSEcmbLRDWO]) i=$((i + 2)) ;;
        -*) i=$((i + 1)) ;;
        *) break ;;
    esac
done
host=${args[i]}
cmd="${args[*]:i+1}"
echo "host $host" >>"$STUB_LOG"
[[ -n $cmd ]] || { echo "stub ssh: no command" >&2; exit 255; }
if [[ -n ${REMOTE_PATH_ONLY:-} ]]; then
    remote_path="$SANDBOX_REMOTE_BIN"
else
    remote_path="$SANDBOX_REMOTE_BIN:$PATH"
fi
HOME="$REMOTE_HOME" PATH="$remote_path" exec sh -c "$cmd"
EOF
    chmod +x "$STUBS/ssh"
    export SANDBOX_REMOTE_BIN="$SANDBOX/remote-bin"

    cat >"$STUBS/build.sh" <<'EOF'
#!/usr/bin/env bash
echo "build $*" >>"$STUB_LOG"
[[ $1 == --arch ]] || exit 2
case $2 in aarch64|armv7l|x86_64) ;; *) echo "unsupported arch: $2" >&2; exit 1 ;; esac
app="$(mktemp -d)"
printf '%s\n' "$FAKE_VERSION" >"$app/VERSION"
cat >"$app/setup.sh" <<'SETUP'
#!/bin/sh
echo "setup $1" >>"$HOME/remote.log"
SETUP
cat >"$app/enter" <<'ENTER'
#!/bin/sh
echo "enter $(cat "$(dirname "$0")/VERSION")" >>"$HOME/remote.log"
ENTER
chmod +x "$app/setup.sh" "$app/enter"
out="$DIST/zsh-portable-$2.tar.gz"
tar -czf "$out" -C "$app" .
printf '%s\n' "$FAKE_VERSION" >"$DIST/zsh-portable-$2.version"
rm -rf "$app"
echo "$out"
EOF
    chmod +x "$STUBS/build.sh"
}

run_zssh() {
    OUTPUT="$(PATH="$STUBS:$PATH" ZSSH_BUILDER="$STUBS/build.sh" \
        XDG_RUNTIME_DIR="$SANDBOX" bash "$ZSSH" "$@" 2>&1)"
    STATUS=$?
}

# ---------------------------------------------------------------------------

CURRENT=""

fail() {
    echo "  FAIL [$CURRENT]: $*"
    echo "    --- output ---"
    sed 's/^/    /' <<<"$OUTPUT"
    echo "    --- calls ---"
    sed 's/^/    /' "$STUB_LOG"
    FAIL=$((FAIL + 1))
    return 1
}

assert_status() {
    [[ $STATUS -eq $1 ]] || fail "expected exit $1, got $STATUS"
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_call_matches() {
    grep -qE -- "$1" "$STUB_LOG" || fail "no call matches: $1"
}

refute_call_matches() {
    ! grep -qE -- "$1" "$STUB_LOG" || fail "unexpected call matches: $1"
}

assert_output_matches() {
    grep -qE -- "$1" <<<"$OUTPUT" || fail "output does not match: $1"
}

assert_file_contains() {
    grep -qE -- "$2" "$1" 2>/dev/null || fail "$1 does not match: $2"
}

run_test() {
    CURRENT="$1"
    setup
    local before=$FAIL
    "$1"
    [[ $FAIL -eq $before ]] && PASS=$((PASS + 1)) && echo "  ok   $1"
    teardown
}

# ---------------------------------------------------------------------------
# Arch mapping
# ---------------------------------------------------------------------------

test_normalize_arch() {
    assert_eq "$(normalize_arch aarch64)" aarch64
    assert_eq "$(normalize_arch arm64)" aarch64
    assert_eq "$(normalize_arch armv7l)" armv7l
    assert_eq "$(normalize_arch armhf)" armv7l
    assert_eq "$(normalize_arch x86_64)" x86_64
    assert_eq "$(normalize_arch amd64)" x86_64
}

test_normalize_arch_rejects_unknown() {
    normalize_arch mips >/dev/null 2>&1 && fail "mips accepted"
    return 0
}

test_eget_system() {
    assert_eq "$(eget_system aarch64)" linux/arm64
    assert_eq "$(eget_system armv7l)" linux/arm
    assert_eq "$(eget_system x86_64)" linux/amd64
}

test_asset_candidates_tries_armv7_first_on_armv7() {
    assert_eq "$(asset_candidates armv7l 'musl|gnu' | tr '\n' ' ')" "armv7,musl musl armv7,gnu gnu "
    assert_eq "$(asset_candidates aarch64 'musl|gnu' | tr '\n' ' ')" "musl gnu "
    assert_eq "$(asset_candidates aarch64 '-' | tr '\n' ' ')" " "
}

# ---------------------------------------------------------------------------
# Secrets guard
# ---------------------------------------------------------------------------

test_check_secrets_passes_clean_dir() {
    mkdir -p "$SANDBOX/b/.config/zsh"
    echo 'alias ll=ls' >"$SANDBOX/b/.config/zsh/.zshrc"
    OUTPUT="$(SECRETS_FILE=/nonexistent check_secrets "$SANDBOX/b" 2>&1)"
    STATUS=$?
    assert_status 0
}

test_check_secrets_rejects_age_file() {
    mkdir -p "$SANDBOX/b"
    touch "$SANDBOX/b/private_env.age"
    OUTPUT="$(SECRETS_FILE=/nonexistent check_secrets "$SANDBOX/b" 2>&1)"
    STATUS=$?
    assert_status 1
    assert_output_matches "private_env.age"
}

test_check_secrets_rejects_secrets_dir() {
    mkdir -p "$SANDBOX/b/.config/secrets"
    touch "$SANDBOX/b/.config/secrets/env"
    OUTPUT="$(SECRETS_FILE=/nonexistent check_secrets "$SANDBOX/b" 2>&1)"
    STATUS=$?
    assert_status 1
}

test_check_secrets_rejects_age_identity_content() {
    mkdir -p "$SANDBOX/b"
    echo "AGE-SECRET-KEY-1QQQQ" >"$SANDBOX/b/notes"
    OUTPUT="$(SECRETS_FILE=/nonexistent check_secrets "$SANDBOX/b" 2>&1)"
    STATUS=$?
    assert_status 1
}

# atuin links the age crate, so its binary holds the identity prefix.
test_check_secrets_ignores_age_prefix_in_binaries() {
    mkdir -p "$SANDBOX/b/bin"
    printf '\x7fELF\x00\x00AGE-SECRET-KEY-\x00' >"$SANDBOX/b/bin/atuin"
    OUTPUT="$(SECRETS_FILE=/nonexistent check_secrets "$SANDBOX/b" 2>&1)"
    STATUS=$?
    assert_status 0
}

test_check_secrets_rejects_local_secret_values() {
    mkdir -p "$SANDBOX/b"
    printf 'GITHUB_TOKEN="ghp_supersecretvalue123"\nSHORT=yes\n' >"$SANDBOX/secrets.env"
    echo "export X=ghp_supersecretvalue123" >"$SANDBOX/b/leak.zsh"
    OUTPUT="$(SECRETS_FILE="$SANDBOX/secrets.env" check_secrets "$SANDBOX/b" 2>&1)"
    STATUS=$?
    assert_status 1
    assert_output_matches "GITHUB_TOKEN"
    grep -q supersecret <<<"$OUTPUT" && fail "secret value printed"
    return 0
}

test_check_secrets_ignores_short_values() {
    mkdir -p "$SANDBOX/b"
    printf 'SHORT=yes\n' >"$SANDBOX/secrets.env"
    echo "yes" >"$SANDBOX/b/file"
    OUTPUT="$(SECRETS_FILE="$SANDBOX/secrets.env" check_secrets "$SANDBOX/b" 2>&1)"
    STATUS=$?
    assert_status 0
}

# ---------------------------------------------------------------------------
# Binary checks
# ---------------------------------------------------------------------------

# fake_elf FILE CLASS MACHINE: write a minimal little-endian ELF header.
fake_elf() {
    {
        printf '\x7fELF'
        printf "\\x$(printf %02x "$2")"
        printf '\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00'
        printf "\\x$(printf %02x $(($3 & 255)))\\x$(printf %02x $(($3 >> 8)))"
    } >"$1"
}

test_elf_arch_detects_targets() {
    fake_elf "$SANDBOX/x" 2 62
    fake_elf "$SANDBOX/a" 2 183
    fake_elf "$SANDBOX/r" 1 40
    assert_eq "$(elf_arch "$SANDBOX/x")" x86_64
    assert_eq "$(elf_arch "$SANDBOX/a")" aarch64
    assert_eq "$(elf_arch "$SANDBOX/r")" armv7l
}

test_elf_arch_rejects_non_elf() {
    echo '#!/bin/sh' >"$SANDBOX/s"
    elf_arch "$SANDBOX/s" >/dev/null 2>&1 && fail "script accepted as ELF"
    return 0
}

test_asset_candidates_adds_package_excludes() {
    asset_args 'musl' | grep -qx -- '--asset=^.deb' || fail "missing ^.deb exclude"
    asset_args 'musl' | grep -qx -- '--asset=musl' || fail "missing musl filter"
    assert_eq "$(asset_args '' | grep -c -- '--asset=^')" "$(asset_args 'x' | grep -c -- '--asset=^')"
}

# ---------------------------------------------------------------------------
# Bundle version
# ---------------------------------------------------------------------------

# zsh-bin's terminfo letter dirs are symlinks to directories.
test_tree_hash_handles_directory_symlinks() {
    mkdir -p "$SANDBOX/t/78" "$SANDBOX/t/79"
    echo cap >"$SANDBOX/t/78/xterm"
    ln -s 78 "$SANDBOX/t/x"
    local first
    first="$(tree_hash "$SANDBOX/t" 2>"$SANDBOX/err")"
    assert_eq "$(cat "$SANDBOX/err")" ""
    assert_eq "${#first}" 16
    ln -sfn 79 "$SANDBOX/t/x"
    [[ $(tree_hash "$SANDBOX/t") != "$first" ]] || fail "link target change not detected"
    return 0
}

# ---------------------------------------------------------------------------
# Cross-built tools
# ---------------------------------------------------------------------------

# fake_cross_env: a tools.tsv with only cross: rows and a cross script that
# writes an aarch64 ELF, or fails for other arches.
fake_cross_env() {
    SCRIPT_DIR="$SANDBOX/portable"
    CACHE="$SANDBOX/cache"
    REFRESH=""
    mkdir -p "$SCRIPT_DIR/cross"
    printf 'fake  cross:fake  fake  -\n' >"$SCRIPT_DIR/tools.tsv"
    {
        echo '#!/usr/bin/env bash'
        echo "echo \"cross \$*\" >>\"$STUB_LOG\""
        echo '[[ $1 == aarch64 ]] || exit 1'
        declare -f fake_elf
        echo 'fake_elf "$2" 2 183'
    } >"$SCRIPT_DIR/cross/fake.sh"
    chmod +x "$SCRIPT_DIR/cross/fake.sh"
}

test_fetch_tools_runs_cross_script() {
    fake_cross_env
    OUTPUT="$(fetch_tools aarch64 "$SANDBOX/bin" 2>&1)"
    assert_call_matches "^cross aarch64 $CACHE/tools/aarch64/fake$"
    assert_eq "$(elf_arch "$SANDBOX/bin/fake")" aarch64
}

test_fetch_tools_reuses_cross_build() {
    fake_cross_env
    fetch_tools aarch64 "$SANDBOX/bin" >/dev/null 2>&1
    : >"$STUB_LOG"
    fetch_tools aarch64 "$SANDBOX/bin2" >/dev/null 2>&1
    refute_call_matches "^cross"
    [[ -x $SANDBOX/bin2/fake ]] || fail "cached build not copied"
}

test_fetch_tools_skips_unsupported_cross_arch() {
    fake_cross_env
    OUTPUT="$(fetch_tools armv7l "$SANDBOX/bin" 2>&1)"
    assert_output_matches "no armv7l build of fake"
    [[ ! -e $SANDBOX/bin/fake ]] || fail "unsupported arch produced a binary"
}

# ---------------------------------------------------------------------------
# setup.sh: disabling tools that can't run
# ---------------------------------------------------------------------------

SETUP="$REPO_DIR/scripts/portable/remote/setup.sh"

# fake_tool NAME EXIT STDERR: a bundled tool that exits EXIT after printing
# STDERR.
fake_tool() {
    mkdir -p "$SANDBOX/app/bin"
    printf '%s\n' "$3" >"$SANDBOX/$1.err"
    printf '#!/bin/sh\ncat "%s" >&2\nexit %s\n' "$SANDBOX/$1.err" "$2" >"$SANDBOX/app/bin/$1"
    chmod +x "$SANDBOX/app/bin/$1"
}

run_setup() {
    OUTPUT="$(sh "$SETUP" "$SANDBOX/final" 2>&1)"
    STATUS=$?
}

test_setup_keeps_tool_that_complains_at_runtime() {
    # tegratop off a Jetson: runs, but logs missing sysfs files.
    fake_tool tegratop 1 "Failed to read /sys/firmware: No such file or directory (os error 2)"
    cp "$SETUP" "$SANDBOX/app/setup.sh"
    SETUP="$SANDBOX/app/setup.sh" run_setup
    assert_status 0
    [[ -x $SANDBOX/app/bin/tegratop ]] || fail "working tool disabled"
    return 0
}

test_setup_disables_tool_needing_newer_glibc() {
    fake_tool cyme 1 "/lib/libc.so.6: version \`GLIBC_2.39' not found (required by cyme)"
    cp "$SETUP" "$SANDBOX/app/setup.sh"
    SETUP="$SANDBOX/app/setup.sh" run_setup
    assert_status 0
    [[ -e $SANDBOX/app/bin/.disabled/cyme ]] || fail "cyme not disabled"
    assert_output_matches "cyme can't run"
}

test_setup_disables_tool_missing_a_library() {
    fake_tool comchan 127 "comchan: error while loading shared libraries: libdbus-1.so.3"
    cp "$SETUP" "$SANDBOX/app/setup.sh"
    SETUP="$SANDBOX/app/setup.sh" run_setup
    [[ -e $SANDBOX/app/bin/.disabled/comchan ]] || fail "comchan not disabled"
}

test_setup_disables_tool_for_wrong_cpu() {
    fake_tool rg 126 "rg: cannot execute binary file: Exec format error"
    cp "$SETUP" "$SANDBOX/app/setup.sh"
    SETUP="$SANDBOX/app/setup.sh" run_setup
    [[ -e $SANDBOX/app/bin/.disabled/rg ]] || fail "rg not disabled"
}

# lnav and others create ~/.lnav, ~/.cache... when they start.
test_setup_probes_tools_outside_home() {
    mkdir -p "$SANDBOX/app/bin" "$SANDBOX/home"
    printf '#!/bin/sh\nmkdir -p "$HOME/.lnav" "${XDG_CACHE_HOME:-$HOME/.cache}/x"\n' >"$SANDBOX/app/bin/lnav"
    chmod +x "$SANDBOX/app/bin/lnav"
    cp "$SETUP" "$SANDBOX/app/setup.sh"
    # As over ssh: no XDG dirs set, so tools fall back to $HOME.
    OUTPUT="$(env -u XDG_CACHE_HOME -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_STATE_HOME \
        HOME="$SANDBOX/home" sh "$SANDBOX/app/setup.sh" "$SANDBOX/final" 2>&1)"
    STATUS=$?
    assert_status 0
    assert_eq "$(ls -A "$SANDBOX/home")" ""
    assert_eq "$(ls -A "$SANDBOX/app" | tr '\n' ' ')" "bin setup.sh "
}

# ---------------------------------------------------------------------------
# Plugin list
# ---------------------------------------------------------------------------

test_filter_plugins_drops_ssh_agent() {
    printf '%s\n' 'zsh-users/zsh-completions kind:fpath path:src' \
        'ohmyzsh/ohmyzsh path:plugins/ssh-agent kind:defer' \
        'ohmyzsh/ohmyzsh path:plugins/git' >"$SANDBOX/p.txt"
    OUTPUT="$(filter_plugins <"$SANDBOX/p.txt")"
    grep -q ssh-agent <<<"$OUTPUT" && fail "ssh-agent kept"
    assert_output_matches "plugins/git"
    assert_output_matches "zsh-completions"
}

# ---------------------------------------------------------------------------
# zssh
# ---------------------------------------------------------------------------

test_zssh_installs_bundle_and_enters() {
    stub_remote
    run_zssh jetson
    assert_status 0
    assert_call_matches "^build --arch aarch64$"
    assert_eq "$(cat "$REMOTE_HOME/.zsh-portable/app/VERSION" 2>/dev/null)" v1
    assert_file_contains "$REMOTE_HOME/remote.log" "^setup $REMOTE_HOME/.zsh-portable/app$"
    assert_file_contains "$REMOTE_HOME/remote.log" "^enter v1$"
    assert_call_matches "^ssh .*-t.* jetson "
}

test_zssh_skips_upload_when_version_matches() {
    stub_remote
    run_zssh jetson
    : >"$REMOTE_HOME/remote.log"
    run_zssh jetson
    assert_status 0
    grep -q '^setup' "$REMOTE_HOME/remote.log" && fail "bundle uploaded again"
    assert_file_contains "$REMOTE_HOME/remote.log" "^enter v1$"
}

test_zssh_replaces_app_and_keeps_state() {
    stub_remote
    run_zssh jetson
    echo "history" >"$REMOTE_HOME/.zsh-portable/state/keep"
    FAKE_VERSION=v2 run_zssh jetson
    assert_status 0
    assert_eq "$(cat "$REMOTE_HOME/.zsh-portable/app/VERSION")" v2
    assert_eq "$(cat "$REMOTE_HOME/.zsh-portable/state/keep")" history
    [[ -e $REMOTE_HOME/.zsh-portable/app.new || -e $REMOTE_HOME/.zsh-portable/app.old ]] \
        && fail "leftover app.new/app.old"
    return 0
}

test_zssh_probe_does_not_read_stdin() {
    stub_remote
    run_zssh jetson
    assert_call_matches "^ssh -n .* jetson uname -m"
}

test_zssh_sends_plain_tar_without_remote_gzip() {
    stub_remote
    # Remote PATH without gzip: tar can't decompress there.
    local t
    for t in sh tar mkdir rm mv cat dirname; do
        ln -s "$(command -v "$t")" "$SANDBOX/remote-bin/$t"
    done
    export REMOTE_PATH_ONLY=1
    run_zssh jetson
    assert_status 0
    assert_eq "$(cat "$REMOTE_HOME/.zsh-portable/app/VERSION" 2>/dev/null)" v1
    assert_output_matches "no gzip"
}

test_zssh_fails_clearly_without_remote_tar() {
    stub_remote
    local t
    for t in sh mkdir rm mv cat dirname; do
        ln -s "$(command -v "$t")" "$SANDBOX/remote-bin/$t"
    done
    export REMOTE_PATH_ONLY=1
    run_zssh jetson
    [[ $STATUS -ne 0 ]] || fail "expected failure"
    assert_output_matches "needs tar"
    refute_call_matches "^ssh .* -t "
}

test_zssh_passes_ssh_options() {
    stub_remote
    run_zssh -p 2222 -J bastion jetson
    assert_status 0
    assert_call_matches "^ssh .*-p 2222 -J bastion jetson"
    assert_call_matches "^host jetson$"
}

test_zssh_maps_remote_arch() {
    stub_remote
    REMOTE_ARCH=armv7l run_zssh pi
    assert_status 0
    assert_call_matches "^build --arch armv7l$"
}

test_zssh_rebuild_flag_forces_build() {
    stub_remote
    run_zssh --rebuild jetson
    assert_status 0
    assert_call_matches "^build --arch aarch64 --force$"
}

test_zssh_unsupported_arch_fails_without_session() {
    stub_remote
    REMOTE_ARCH=mips run_zssh router
    [[ $STATUS -ne 0 ]] || fail "expected failure"
    refute_call_matches "^ssh .* -t "
}

test_zssh_requires_host() {
    stub_remote
    run_zssh
    assert_status 2
    assert_output_matches "[Uu]sage"
}

test_zssh_custom_remote_dir() {
    stub_remote
    ZSSH_REMOTE_DIR="$SANDBOX/elsewhere" run_zssh jetson
    assert_status 0
    assert_eq "$(cat "$SANDBOX/elsewhere/app/VERSION" 2>/dev/null)" v1
}

# ---------------------------------------------------------------------------
# End to end (opt-in)
# ---------------------------------------------------------------------------

# e2e ARCH PLATFORM IMAGE [DOCKER_ARGS...]: build a real bundle and run it
# offline in IMAGE.
e2e() {
    local arch=$1 platform=$2 image=$3 name="e2e $1 on ${3##*/}"
    shift 3
    echo "e2e: building $arch bundle"
    local bundle
    bundle="$("$BUILD" --arch "$arch" | tail -n1)" || { echo "  FAIL $name: build"; FAIL=$((FAIL + 1)); return; }
    local checks='
set -e
# Under QEMU_LD_PREFIX the container itself is x86_64; only the bundle is arm.
if [ -z "${QEMU_LD_PREFIX:-}" ] && [ "$(uname -m)" != "'"$arch"'" ]; then
    echo "wrong uname: $(uname -m)"; exit 1
fi
mkdir -p $HOME && cd $HOME
# Like the Jetsons (Yocto): no system terminfo, so zsh must use its own.
rm -rf /etc/terminfo /lib/terminfo /usr/share/terminfo /usr/lib/terminfo
# Host dotfiles must never be sourced: on the Jetsons ~/.aliases holds
# commands that drive the camera.
echo "touch \$HOME/ALIASES_SOURCED" >$HOME/.aliases
echo "touch \$HOME/ZSHENV_LOCAL_SOURCED" >$HOME/.zshenv.local
d=$HOME/.zsh-portable
mkdir -p $d/app.new $d/state
tar -xzf /bundle.tar.gz -C $d/app.new
sh $d/app.new/setup.sh $d/app 2>setup.err || { cat setup.err; exit 1; }
disabled=$(ls $d/app.new/bin/.disabled | sort | tr "\n" " ")
if [ "$disabled" != "'"$E2E_DISABLED"'" ]; then
    echo "disabled: [$disabled] expected: ['"$E2E_DISABLED"']"; cat setup.err; exit 1
fi
mv $d/app.new $d/app
# Every tool must run, inside the bundle environment like real use.
$d/app/enter -c '"'"'
for tool in $XDG_BIN_HOME/*; do
    for flag in --version -V -v version; do
        "$tool" $flag >/dev/null 2>&1 && continue 2
    done
    echo "broken: $tool"; exit 1
done'"'"' </dev/null
# The bundled tmux (aarch64 only) must load its config and plugins offline.
$d/app/enter -c '"'"'
(( $+commands[tmux] )) || exit 0
tmux -L e2e new-session -d -s e2e || { print "tmux failed to start"; exit 1 }
session=$(tmux -L e2e show -gv @catppuccin_status_session)
right=$(tmux -L e2e show -gv status-right)
tmux -L e2e kill-server
[[ -n $session && $right == *continuum_save.sh* ]] || { print "tmux plugins missing"; exit 1 }
print TMUX_OK'"'"' </dev/null
cd /tmp
$d/app/enter -ic "
  set -e
  zmodload zsh/terminfo
  (( \${#terminfo} > 0 )) || { print \"no terminfo for \$TERM\"; exit 1; }
  [[ -n \$terminfo[cuu1] && -n \$terminfo[cub1] ]]
  whence -w git_prompt_info
  alias ll >/dev/null || whence -w ll
  [[ \$PROMPT == *┌──* ]]
  [[ \$HISTFILE == \$HOME/.zsh-portable/state/* ]]
  (( \${+commands[fzf]} && \${+commands[eza]} && \${+commands[zoxide]} ))
  [[ -z \$(ls \$HOME/.config/secrets 2>/dev/null) ]]
  print PORTABLE_OK
"
# Nothing may be written outside ~/.zsh-portable.
for f in ALIASES_SOURCED ZSHENV_LOCAL_SOURCED; do
    [ ! -e $HOME/$f ] || { echo "host dotfile sourced: $f"; exit 1; }
done
# Unpacked as root, nothing may stay owned by the build user'"'"'s uid.
foreign=$(find $d/app ! -user 0 | head -3)
[ "$(id -u)" != 0 ] || [ -z "$foreign" ] || { echo "not owned by root: $foreign"; exit 1; }
extra=$(cd $HOME && ls -A | grep -vxE ".zsh-portable|.bashrc|.profile|.aliases|.zshenv.local|setup.err" || true)
[ -z "$extra" ] || { echo "leaked into HOME: $extra"; exit 1; }
echo HERMETIC_OK
'
    local out
    out="$(docker run --rm --network none --platform "$platform" "$@" \
        -v "$bundle:/bundle.tar.gz:ro" -e HOME=/tmp/e2e-home -e TERM=xterm-256color \
        "$image" sh -c "$checks" 2>&1)"
    if grep -q PORTABLE_OK <<<"$out" && grep -q HERMETIC_OK <<<"$out"; then
        PASS=$((PASS + 1)); echo "  ok   $name"
    else
        FAIL=$((FAIL + 1)); echo "  FAIL $name"; sed 's/^/    /' <<<"$out"
    fi
}

# ---------------------------------------------------------------------------

for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
    run_test "$t"
done

# Oldest likely OS per target: JetPack 4 is Ubuntu 18.04, Raspberry Pi OS is
# Debian. arm64/arm/qos need qemu binfmt (tonistiigi/binfmt --install
# arm64,arm).
QOS_IMAGE=${QOS_IMAGE:-gitlab.quantum-systems.com:5050/ai/repo/devcontainer-yocto:latest}
if [[ -n ${PORTABLE_E2E:-} ]]; then
    for arch in ${PORTABLE_E2E_ARCHES:-x86_64}; do
        case $arch in
            # E2E_DISABLED: tools setup.sh must disable there, sorted, each
            # followed by a space (glibc too old, or libdbus missing).
            x86_64) E2E_DISABLED="comchan cyme " e2e x86_64 linux/amd64 ubuntu:22.04 ;;
            aarch64) E2E_DISABLED="comchan cyme tmux " e2e aarch64 linux/arm64 ubuntu:18.04 ;;
            armv7l) E2E_DISABLED="" e2e armv7l linux/arm/v7 debian:bookworm-slim ;;
            # The Jetsons' Yocto OS: x86_64 SDK container whose aarch64
            # sysroot holds the target's libraries, used through qemu.
            qos) E2E_DISABLED="" e2e aarch64 linux/amd64 "$QOS_IMAGE" \
                -e QEMU_LD_PREFIX=/opt/nos/sysroots/armv8a-oe4t-linux ;;
        esac
    done
fi

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
