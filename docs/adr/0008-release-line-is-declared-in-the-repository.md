# The release line is declared in the repository, not inferred from tags

A hybrid component's `major.minor` comes from the first line of `.release-line` in its repository;
tags on that line supply only the next patch. Until 2026-09 the TeamCity meta-runner derived the
whole version from the newest `v*` tag, which left no way to open a new line except pushing a tag
such as `v2.5.0` by hand. That tag had no GitHub Release and no release-log entry, so downstream
tracking attributed the pull requests merged before it to a version that never existed; six issues
across two components were left unassigned in 2026-07. Tags record releases that happened; intent
about the next version has to live somewhere a build can read before anyone decides to release,
because the version is fixed in the first build of the chain and the QA image already carries it.

## Considered options

- **A TeamCity project parameter** holding the line: the same code, no repository change. Rejected
  because the bump is invisible to GitHub and to the release contents, a missing parameter stops
  every compile build from starting, and one value per project cannot give a maintenance branch its
  own line.
- **A suffixed marker tag** (`v2.5.0-next`, as axion-release's `markNextVersion`): keeps the habit.
  Rejected because it is still a hand-made tag and downstream tracking would have to learn to
  ignore it.
- **Conventional commits** deciding the bump: no manual step at all. Deferred, not rejected: about
  a third of hybrid commits carry a prefix today, so the bump would be random. If the convention
  becomes mandatory it can write the file.

## Consequences

The file holds `major.minor` only, on purpose. A pinned full version (GitVersion's `next-version`,
release-please's `release-as`) is stale the moment it is released and has to be edited again; a
line stays valid until the next line opens. A line *behind* the newest release is refused on the
default branch, because the alternative is a lower version tagged, published and registered before
the post-processing step's "went backwards" check stops it — a repair, not a failed build. The
check is scoped to the default branch rather than dropped, so a maintenance branch can still
declare an older line, which is half of why the file exists. A line *ahead* cannot be checked at
all: it is indistinguishable from opening a line, so the pull request that changes the file is the
only guard there.

A repository without the file keeps the old rule. That fallback exists so the meta-runner can be
re-uploaded on every TeamCity server that runs it before any repository carries the file; it is
not a second supported way to version.
