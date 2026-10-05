#!/usr/bin/env bash
# publish.sh PACKAGE.hpkg...
#
# Run in the CI checkout of an application repository after a build of its
# default branch:
#   1. replaces the assets of the rolling GitHub release "latest" (a
#      prerelease whose tag is moved to the built commit) with PACKAGEs;
#   2. rewrites the "Latest builds" section of README.md (between the
#      airos-ci markers; added before the first "## " heading if missing)
#      with links to them, and pushes that as a "[skip ci]" commit.
#
# Needs GH_TOKEN (the job's GITHUB_TOKEN with contents: write), GITHUB_SHA,
# GITHUB_REPOSITORY and GITHUB_REF_NAME, as set by GitHub Actions.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

[[ $# -gt 0 ]] || die "no packages to publish"
: "${GITHUB_REPOSITORY:?}" "${GITHUB_SHA:?}" "${GITHUB_REF_NAME:?}"
README=${README:-README.md}
TAG=latest
short=${GITHUB_SHA:0:7}
date=$(date -u +%Y-%m-%d)
revision_x86=$(cat "$AIROS_SDK/x86_64/revision" 2>/dev/null || echo unknown)
revision_arm=$(cat "$AIROS_SDK/arm64/revision" 2>/dev/null || echo unknown)

note "release $TAG -> $short"
notes=$(mktemp)
{
	echo "Built by air/OS CI from $short on $date."
	echo
	echo "Haiku SDK: x86_64 $revision_x86, arm64 $revision_arm."
	echo
	echo '| Package | SHA-256 |'
	echo '|---|---|'
	for package in "$@"; do
		echo "| $(basename "$package") | \`$(sha256sum "$package" | cut -d' ' -f1)\` |"
	done
	echo
	echo 'Install on air/OS or Haiku with `pkgman install <file>`, or copy the file into `/boot/system/packages`.'
} > "$notes"
# Recreate the release so the tag follows the built commit and old assets go.
gh release delete "$TAG" --cleanup-tag --yes >/dev/null 2>&1 || true
gh release create "$TAG" --prerelease --target "$GITHUB_SHA" \
	--title "Latest air/OS build ($short)" --notes-file "$notes" "$@"
rm -f "$notes"

# The asset names as GitHub stored them (it may rewrite characters such as ~).
assets=$(gh release view "$TAG" --json assets --jq '.assets[] | "\(.name)\t\(.url)"')

note "README section"
python3 - "$README" "$GITHUB_REPOSITORY" "$short" "$date" "$revision_x86" "$revision_arm" "$assets" <<'EOF'
import re, sys
readme, repo, short, date, rev_x86, rev_arm, assets = sys.argv[1:8]
start, end = '<!-- airos-ci:latest-builds:start -->', '<!-- airos-ci:latest-builds:end -->'
rows = []
for line in assets.splitlines():
    if not line.strip():
        continue
    name, url = line.split('\t')
    arch = 'x86_64' if name.endswith('x86_64.hpkg') else 'arm64' if name.endswith('arm64.hpkg') else '?'
    rows.append((arch, name, url))
rows.sort()
block = [start, '## Latest builds', '',
         f'Built automatically by air/OS CI from commit `{short}` on {date} '
         f'([all files](https://github.com/{repo}/releases/tag/latest)).', '',
         '| Architecture | Package |', '|---|---|']
block += [f'| {arch} | [{name}]({url}) |' for arch, name, url in rows]
block += ['', 'Install with `pkgman install <file>`, or copy the file into `/boot/system/packages`. '
          f'Haiku SDK: x86_64 {rev_x86}, arm64 {rev_arm}.', end]
text = open(readme).read()
new = '\n'.join(block)
if start in text and end in text:
    text = re.sub(re.escape(start) + r'.*?' + re.escape(end), lambda m: new, text, flags=re.S)
else:
    m = re.search(r'^## ', text, flags=re.M)
    if m:
        text = text[:m.start()] + new + '\n\n' + text[m.start():]
    else:
        text = text.rstrip('\n') + '\n\n' + new + '\n'
open(readme, 'w').write(text)
EOF

if git diff --quiet -- "$README"; then
	echo "README unchanged"
	exit 0
fi
git -c user.name="air/OS CI" -c user.email="airos-ci@users.noreply.github.com" \
	commit -q -m "README: latest air/OS builds ($short) [skip ci]" -- "$README"
for attempt in 1 2 3 4 5; do
	if git push -q origin "HEAD:$GITHUB_REF_NAME"; then
		echo "README pushed"
		exit 0
	fi
	# Someone pushed meanwhile: put the README commit on top and retry.
	git fetch -q origin "$GITHUB_REF_NAME" && git rebase -q FETCH_HEAD
	sleep $((attempt * 2))
done
die "could not push the README update"
