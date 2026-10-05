# Source after lib/env.sh: check out third-party code from the jmgasper forks
# at the commits pinned in forks/forks.lock.json.

FORKS_LOCK=${FORKS_LOCK:-$AIROS_CI/forks/forks.lock.json}

# fork_info NAME FIELD: a field of the lock entry (url, commit, branch, base, repo)
fork_info() {
	python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]][sys.argv[3]])' \
		"$FORKS_LOCK" "$1" "$2"
}

# fork_checkout NAME DEST: DEST becomes a clean tree of the pinned commit
# (with submodules, which point at jmgasper forks too). The clone is cached in
# $AIROS_CACHE/forks and shared by all jobs; the checkout is a worktree.
fork_checkout() {
	local name=$1 dest=$2 url commit cache
	url=$(fork_info "$name" url)
	commit=$(fork_info "$name" commit)
	cache=$AIROS_CACHE/forks/$(fork_info "$name" repo).git
	mkdir -p "$AIROS_CACHE/forks"
	with_lock "fork-$name" bash -c '
		set -e
		[[ -d $1 ]] || git clone -q --bare --filter=blob:none "$2" "$1"
		git -C "$1" cat-file -e "$3^{commit}" 2>/dev/null || git -C "$1" fetch -q --filter=blob:none origin "$3"
	' _ "$cache" "$url" "$commit"
	rm -rf "$dest"
	mkdir -p "$(dirname "$dest")"
	git -C "$cache" worktree prune
	with_lock "fork-$name" git -C "$cache" worktree add -q --detach --force "$dest" "$commit"
	if [[ -f $dest/.gitmodules ]]; then
		git -C "$dest" submodule -q update --init --recursive
	fi
	FORK_COMMIT=$commit
	echo "$name: $(fork_info "$name" repo)@$(fork_info "$name" branch) ${commit:0:12}"
}
