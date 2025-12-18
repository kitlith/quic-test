#!/usr/bin/env bash

# change_id of the merge commit
MERGE=ooxtuqvy

source workflow/upstream-commits

maybe_create_remote() {
	local remote_name="$1"
	local remote_url="$2"

	if jj git remote list | cut -d ' ' -f 1 | grep -q "$remote_name"; then
		: # remote already exists, do nothing
	else
		echo "-- Adding upstream remote '$remote_url' for remote '$remote_name'"
		jj git remote add "$remote_name" "$remote_url"
	fi

}

filter_remote() {
	local remote_name="$1"
	local remote_branch="$2"
	local filter_file="$3"
	local trailer_id="$4"
	echo "-- Fetching upstream $remote_name"
	jj git fetch --remote "$remote_name" -b "$remote_branch"
	if [ -z "$UPDATE" ]; then
		local commit="${COMMITS[$remote_name]}"
		echo "-- Pinning $remote_name to current commit ($commit)"
		jj bookmark create -r "$commit" "tmp-$remote_name"
	else
	    jj bookmark create -r "main@${remote_name}" "tmp-$remote_name"
	fi
	echo "-- Updating $remote_name subset"
	josh-filter --update refs/heads/${remote_name}-subset dummy-not-filter --file "$filter_file" refs/heads/tmp-${remote_name}
}

echo "-- Current operation ID (if you need to revert): $(jj op log --no-graph -n 1 -T 'id.short()')"

if jj bookmark list -T 'name ++ "\n"' | grep -q workflow; then
    : # local bookmark already exists, do nothing
else
    jj bookmark track workflow@origin
fi

maybe_create_remote dotnet https://github.com/dotnet/runtime.git
filter_remote dotnet main workflow/dotnet-filter Dotnet-Commit
maybe_create_remote msquic https://github.com/microsoft/msquic.git
filter_remote msquic main workflow/msquic-filter MsQuic-Commit



echo "-- Rebasing onto updated upstreams"
abandon_parents="$(jj log --no-graph -T 'change_id ++ " | "' -r "$MERGE- ~ workflow::") none()"
workflow_parent="$(jj log --no-graph -T 'change_id ++ " | "' -r "$MERGE- & workflow::") none()"
jj rebase -s $MERGE -d "$workflow_parent" -d dotnet-subset -d msquic-subset

cat << EOF > workflow/upstream-commits
declare -A COMMITS=(
    ["msquic"]="$(jj log --no-graph -T 'commit_id' -r tmp-msquic --no-pager --color=never)"
    ["dotnet"]="$(jj log --no-graph -T 'commit_id' -r tmp-dotnet --no-pager --color=never)"
)
EOF

# if we are using a new set of upstream commits
if [[ "$(jj log -r 'files(workflow/upstream-commits) & @' --count)" != "0" ]]; then
    echo "-- Updating workflow branch with new upstream commits"
    jj squash workflow/upstream-commits -A "$workflow_parent"
fi

jj bookmark forget tmp-msquic
jj bookmark forget tmp-dotnet

echo "-- Abandoning old versions of upstreams"
jj abandon -r "..($abandon_parents) ~ ..$MERGE"
