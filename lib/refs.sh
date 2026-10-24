# lib/refs.sh — sourced by install.sh and tools/make-bundle.sh, so both pick versions the same way.
# resolve REPO [REF] prints "<ref> <commit> <.deb asset url or ->".
# Tags, branches and commits are resolved with git ls-remote (no API rate limit; annotated tags are peeled to their
# commit). The GitHub API is called once, for the release list: the latest vX.Y.Z release and its .deb assets. When
# that call fails (the 60-an-hour unauthenticated limit, say) the newest vX.Y.Z tag stands in.
resolve() {
  local repo=$1 ref=${2:-} rels refs sha deb
  rels=$(curl -fsSL "https://api.github.com/repos/$repo/releases?per_page=100" 2>/dev/null || true)
  refs=$(git ls-remote "https://github.com/$repo" 2>/dev/null) || return 1
  if [ -z "$ref" ]; then
    ref=$(python3 -I -c '
import json, re, sys
rs = [r["tag_name"] for r in json.loads(sys.argv[1])
      if not r["draft"] and not r["prerelease"] and re.fullmatch(r"v\d+(\.\d+)*", r["tag_name"])]
print(max(rs, key=lambda t: [int(x) for x in t[1:].split(".")]) if rs else "")' "$rels" 2>/dev/null || true)
    [ -n "$ref" ] || ref=$(awk '{print $2}' <<<"$refs" | sed -n 's|^refs/tags/\(v[0-9][0-9.]*\)$|\1|p' | sort -V | tail -1)
    [ -n "$ref" ] || return 1
  fi
  sha=$(awk -v a="refs/tags/$ref^{}" -v b="refs/tags/$ref" -v c="refs/heads/$ref" '
    $2 == a {pa = $1} $2 == b {pb = $1} $2 == c {pc = $1} END {print pa ? pa : pb ? pb : pc}' <<<"$refs")
  if [ -z "$sha" ]; then
    # A commit hash (short or full): it exists if GitHub serves its archive.
    [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]] || return 1
    curl -fsIL -o /dev/null "https://github.com/$repo/archive/$ref.tar.gz" 2>/dev/null || return 1
    # Use the full hash when a branch or tag points at it, so it compares equal to that ref later.
    sha=$(awk -v p="$ref" 'index($1, p) == 1 {print $1; exit}' <<<"$refs")
    [ -n "$sha" ] || sha=$ref
  fi
  deb=$(python3 -I -c '
import json, sys
for r in json.loads(sys.argv[1]):
    if r["tag_name"] == sys.argv[2]:
        a = [x["browser_download_url"] for x in r.get("assets", []) if x["name"].endswith(("_amd64.deb", "_all.deb"))]
        print(a[0] if a else "-")
        break' "$rels" "$ref" 2>/dev/null || true)
  echo "$ref $sha ${deb:--}"
}
