#!/usr/bin/env bash
# Publish only the prepared packaging files; never source PKGBUILD here.
set -euo pipefail
package=${1:?usage: publish_aur.sh <prepared-package-directory>}
: "${AUR_SSH_PRIVATE_KEY:?Set repository secret AUR_SSH_PRIVATE_KEY}"
: "${AUR_MAINTAINER:?Set repository secret AUR_MAINTAINER (Name <email>)}"
: "${RUNNER_TEMP:?Run in GitHub Actions}"
[[ ${GITHUB_REPOSITORY:-} == Yukaii/misstype &&
   ( ${GITHUB_REF:-} == refs/heads/main || ${GITHUB_REF:-} == refs/heads/ci/aur-publishing ) ]] || {
    echo 'AUR publication is restricted to Yukaii/misstype main or ci/aur-publishing.' >&2
    exit 1
}
for file in PKGBUILD .SRCINFO cxx20.patch LICENSE; do
    [[ -f $package/$file && ! -L $package/$file ]]
done
grep -Fxq 'pkgbase = fcitx5-misstype-git' "$package/.SRCINFO"
grep -Fxq "# Maintainer: $AUR_MAINTAINER" "$package/PKGBUILD"

work=$(mktemp -d "$RUNNER_TEMP/aur-publish.XXXXXX")
trap 'rm -rf "$work"' EXIT
umask 077
# Verify the scanned key against AUR's independently published fingerprint:
# https://aur.archlinux.org/ (Ed25519). A mismatch must fail closed.
ssh-keyscan -T 15 -t ed25519 aur.archlinux.org > "$work/known_hosts"
fingerprint=$(ssh-keygen -lf "$work/known_hosts" -E sha256 | cut -d ' ' -f 2)
[[ $fingerprint == 'SHA256:RFzBCUItH9LZS0cKB5UE6ceAYhBD5C8GeOBip8Z11+4' ]] || {
    echo 'AUR host key does not match its published fingerprint.' >&2
    exit 1
}
printf '%s\n' "$AUR_SSH_PRIVATE_KEY" > "$work/key"
unset AUR_SSH_PRIVATE_KEY
printf -v GIT_SSH_COMMAND 'ssh -i %q -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=%q' "$work/key" "$work/known_hosts"
export GIT_SSH_COMMAND
git clone ssh://aur@aur.archlinux.org/fcitx5-misstype-git.git "$work/repo"
for file in PKGBUILD .SRCINFO cxx20.patch LICENSE; do
    install -m644 "$package/$file" "$work/repo/$file"
done
git -C "$work/repo" add -- PKGBUILD .SRCINFO cxx20.patch LICENSE
if git -C "$work/repo" diff --cached --quiet; then
    printf '### AUR\n\nPackaging already matches AUR; no commit or push needed.\n' >> "$GITHUB_STEP_SUMMARY"
    exit 0
fi
git -C "$work/repo" diff --cached --stat
git -C "$work/repo" -c user.name='Misstype AUR automation' \
    -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
    commit -m "Update packaging from misstype ${GITHUB_SHA:0:12}"
# Never force: a concurrent maintainer update must be reviewed before retrying.
git -C "$work/repo" push origin HEAD:master
printf '### AUR\n\nPublished packaging to [fcitx5-misstype-git](https://aur.archlinux.org/packages/fcitx5-misstype-git).\n' >> "$GITHUB_STEP_SUMMARY"
