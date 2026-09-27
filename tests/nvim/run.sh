#!/usr/bin/env bash
# Run one headless Neovim test in a throwaway git repo, isolated from the user's git config.
# Usage: run.sh <nvim> <test.lua>
set -euo pipefail

nvim=${1:?usage: run.sh <nvim> <test.lua>}
test=${2:?usage: run.sh <nvim> <test.lua>}
test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
bash_bin=$(command -v bash)
real_git=$(command -v git)

work=$(mktemp -d)
# The config creates some state dirs read-only; cleanup must not mask the test's exit status
trap '{ chmod -R u+w "$work"; rm -rf "$work"; } 2>/dev/null || true' EXIT
export HOME=$work/home TMPDIR=$work
export XDG_CONFIG_HOME=$work/config XDG_DATA_HOME=$work/data XDG_STATE_HOME=$work/state XDG_CACHE_HOME=$work/cache
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
mkdir -p "$HOME" "$work/bin" "$work/fake-git-state" "$work/repo"

# The Nix sandbox has no /usr/bin/env, so wrap the fake git with an absolute bash
printf '#!%s\nexec %s %q "$@"\n' "$bash_bin" "$bash_bin" "$test_dir/fake-git" >"$work/bin/git"
chmod +x "$work/bin/git"

cd "$work/repo"
"$real_git" init -q -b main
echo x >file.txt
"$real_git" add file.txt
"$real_git" commit -q -m init

status=0
TEST_DIR=$test_dir REAL_GIT=$real_git BASH_BIN=$bash_bin \
  FAKE_GIT_BIN=$work/bin FAKE_GIT_STATE=$work/fake-git-state \
  timeout 300 "$nvim" --headless -c "luafile $test" || status=$?
echo "nvim exited with status $status"
exit "$status"
