#!/usr/bin/env bash
#
# Tests for the zsh-config devcontainer feature (features/src/zsh-config).
#
# Unit tests need neither docker nor network. With FEATURE_E2E=1 and
# FEATURE_BUNDLE=<path to zsh-portable-dev-x86_64.tar.gz>, install.sh is also
# run as root in ubuntu:24.04 and debian:12 and the result checked offline.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE="$REPO_DIR/features/src/zsh-config"
JSON="$FEATURE/devcontainer-feature.json"
INSTALL="$FEATURE/install.sh"

PASS=0
FAIL=0
CURRENT=""

setup() {
    SANDBOX="$(mktemp -d)"
    OUTPUT=""
    STATUS=0
}

teardown() {
    rm -rf "$SANDBOX"
}

fail() {
    echo "  FAIL [$CURRENT]: $*"
    echo "    --- output ---"
    sed 's/^/    /' <<<"$OUTPUT"
    FAIL=$((FAIL + 1))
    return 1
}

assert_eq() {
    [[ $1 == "$2" ]] || fail "expected '$2', got '$1'"
}

assert_contains() {
    [[ $1 == *"$2"* ]] || fail "expected to contain '$2'"
}

run_test() {
    CURRENT="$1"
    setup
    local before=$FAIL
    "$1"
    [[ $FAIL -eq $before ]] && PASS=$((PASS + 1)) && echo "  ok   $1"
    teardown
}

# jq_json FILTER: evaluate FILTER against the feature's JSON (python, no jq dep).
json() {
    python3 - "$JSON" "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(json.dumps(eval(sys.argv[2], {"d": d})))
EOF
}

test_json_valid() {
    OUTPUT=$(json 'd["id"]' 2>&1) || fail "invalid JSON"
    assert_eq "$OUTPUT" '"zsh-config"'
}

test_json_options() {
    OUTPUT=$(json '[d["options"][k]["default"] for k in ("version", "bundleUrl", "defaultShell")]' 2>&1)
    assert_eq "$OUTPUT" '["latest", "", true]'
}

test_json_mount() {
    OUTPUT=$(json 'd["mounts"]' 2>&1)
    assert_eq "$OUTPUT" '[{"source": "zsh-config-state-${devcontainerId}", "target": "/var/lib/zsh-config", "type": "volume"}]'
}

test_json_vscode_profile() {
    OUTPUT=$(json 'd["customizations"]["vscode"]["settings"]' 2>&1)
    assert_contains "$OUTPUT" '"terminal.integrated.defaultProfile.linux": "zsh"'
    assert_contains "$OUTPUT" '{"zsh": {"path": "/usr/local/bin/zsh", "args": ["-l"]}}'
}

test_install_syntax() {
    OUTPUT=$(bash -n "$INSTALL" 2>&1) || fail "bash -n failed"
    OUTPUT=$(sh -n "$INSTALL" 2>&1) || fail "sh -n failed"
}

test_rejects_non_x86() {
    mkdir -p "$SANDBOX/stub"
    printf '#!/bin/sh\necho aarch64\n' >"$SANDBOX/stub/uname"
    chmod +x "$SANDBOX/stub/uname"
    OUTPUT=$(PATH="$SANDBOX/stub:$PATH" sh "$INSTALL" 2>&1) || STATUS=$?
    [[ $STATUS -ne 0 ]] || fail "expected non-zero exit"
    assert_contains "$OUTPUT" "zsh-config: only x86_64 bundles are published"
}

# ---- e2e (docker) ----

e2e_image() {
    local image=$1 bundle_dir=$2 tag="zsh-config-e2e-$RANDOM$RANDOM"
    local vol="$tag-state" box="$tag-box" out rc
    local ok=1

    check() { # NAME CMD...: run CMD in the committed image as dev, offline
        local name=$1
        shift
        out=$(docker run --rm --network none -u dev -v "$vol:/var/lib/zsh-config" \
            -w /home/dev "$tag" sh -c "$*" 2>&1) && rc=0 || rc=$?
        OUTPUT=$out
        echo "    [$image] $name: rc=$rc"
        return $rc
    }

    OUTPUT=$(docker run --name "$box" -v "$FEATURE:/feature:ro" -v "$bundle_dir:/bundle:ro" "$image" sh -c '
        set -e
        command -v curl >/dev/null && echo "curl preinstalled" || echo "no curl"
        useradd -m -s /bin/bash dev
        echo "# mine" >/home/dev/.zshenv
        chown dev:dev /home/dev/.zshenv
        _REMOTE_USER=dev _REMOTE_USER_HOME=/home/dev \
            BUNDLEURL=file:///bundle/zsh-portable-dev-x86_64.tar.gz sh /feature/install.sh
    ' 2>&1) || { fail "[$image] install.sh failed"; docker rm -f "$box" >/dev/null; return; }
    echo "    [$image] install: $(grep -c . <<<"$OUTPUT") lines, $(grep -m1 'curl' <<<"$OUTPUT")"
    docker commit "$box" "$tag" >/dev/null
    docker rm -f "$box" >/dev/null

    check "lsd --version" '~/.local/bin/lsd --version' || { fail "[$image] lsd"; ok=0; }
    check "zsh -i offline" "zsh -i -c 'print -r -- \$ZSH_PORTABLE; echo ok'"
    [[ $rc -eq 0 && $out == *ok* ]] || { fail "[$image] zsh -i"; ok=0; }
    [[ $out != *"Cloning"* && $out != *"Installing"* ]] || { fail "[$image] tried network"; ok=0; }
    check "theme loaded" "zsh -i -c 'print -r -- \$ZSH_THEME'"
    [[ $out == *yupps* ]] || { fail "[$image] theme '$out'"; ok=0; }
    check "login shell" 'getent passwd dev | cut -d: -f7'
    [[ $out == /usr/local/bin/zsh ]] || { fail "[$image] login shell '$out'"; ok=0; }
    check "zshenv backup" 'cat ~/.zshenv.pre-zsh-config'
    [[ $out == "# mine" ]] || { fail "[$image] zshenv backup"; ok=0; }
    check "history" "zsh -i -c 'print -s hi; fc -W' >/dev/null 2>&1; test -s /var/lib/zsh-config/zsh/history && echo yes"
    [[ $out == *yes ]] || { fail "[$image] history"; ok=0; }

    # Corrupted sum: install.sh must fail before touching the home.
    local bad="$SANDBOX/bad"
    mkdir -p "$bad"
    ln -f "$bundle_dir/zsh-portable-dev-x86_64.tar.gz" "$bad/" 2>/dev/null \
        || cp "$bundle_dir/zsh-portable-dev-x86_64.tar.gz" "$bad/"
    echo "0000000000000000000000000000000000000000000000000000000000000000  zsh-portable-dev-x86_64.tar.gz" >"$bad/SHA256SUMS"
    out=$(docker run --rm -v "$FEATURE:/feature:ro" -v "$bad:/bundle:ro" "$image" sh -c '
        useradd -m dev
        _REMOTE_USER=dev _REMOTE_USER_HOME=/home/dev \
            BUNDLEURL=file:///bundle/zsh-portable-dev-x86_64.tar.gz sh /feature/install.sh >/dev/null 2>&1
        echo "rc=$?"
        test -e /home/dev/.local/bin/zsh && echo "zsh present" || echo "no zsh"
    ' 2>&1)
    OUTPUT=$out
    echo "    [$image] bad sum: $(tr '\n' ' ' <<<"$out")"
    [[ $out != *"rc=0"* && $out == *"no zsh"* ]] || { fail "[$image] bad sum"; ok=0; }

    docker rmi -f "$tag" >/dev/null
    docker volume rm -f "$vol" >/dev/null
    [[ $ok -eq 1 ]]
}

test_e2e() {
    local src=${FEATURE_BUNDLE:?FEATURE_BUNDLE must point at the dev bundle}
    local dir="$SANDBOX/bundle"
    mkdir -p "$dir"
    ln "$src" "$dir/zsh-portable-dev-x86_64.tar.gz" 2>/dev/null \
        || cp "$src" "$dir/zsh-portable-dev-x86_64.tar.gz"
    (cd "$dir" && sha256sum zsh-portable-dev-x86_64.tar.gz >SHA256SUMS)
    local image
    for image in ubuntu:24.04 debian:12; do
        e2e_image "$image" "$dir"
    done
}

TESTS=(test_json_valid test_json_options test_json_mount test_json_vscode_profile
    test_install_syntax test_rejects_non_x86)
[[ -z ${FEATURE_E2E:-} ]] || TESTS+=(test_e2e)

for t in "${TESTS[@]}"; do
    run_test "$t"
done

echo
echo "$PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
