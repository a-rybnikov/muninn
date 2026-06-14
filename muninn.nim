## muninn — a quiet watcher of GitHub activity.
##
## "Huginn ok Muninn fljuga hverjan dag ..." — Grimnismal 20.
## Muninn, Odin's raven named "Memory", flies the world each day
## and returns with news. This little daemon does the same with GitHub.
##
## Pure Nim: std/httpclient + std/json. No external processes.
##
## Two modes of one binary:
##   muninn          — daemon: poll GitHub, write snapshot + digest;
##   muninn status   — render a table from the last snapshot (no network).
##
## Environment:
##   MUNINN_USER   — whose GitHub to watch (default: the token's owner)
##   MUNINN_HOME   — where state lives     (default: ~/.config/muninn)
##   GITHUB_TOKEN  — API token; falls back to the GitHub CLI's token
## The token is never written to a log.
##
## Build:  nim c -d:release -d:ssl --hints:off muninn.nim

import std/[os, json, strutils, strformat, httpclient, times]

let
  userCfg = getEnv("MUNINN_USER", "")
  home    = getEnv("MUNINN_HOME", getConfigDir() / "muninn")

const
  Base  = "https://api.github.com/"
  Title = "M U N I N N"
  Quote = "»Doch bangt mir mehr um Munin.«"   # Grimnismal 20

# -- Token: from env, else from the GitHub CLI's config. Never logged.
proc readToken(): string =
  result = getEnv("GITHUB_TOKEN")
  if result.len > 0: return
  let cli = getHomeDir() / ".config" / "gh" / "hosts.yml"
  if fileExists(cli):
    for line in lines(cli):
      if "oauth_token:" in line:
        return line.split("oauth_token:", 1)[1].strip()

proc ask(http: HttpClient, path: string): JsonNode =
  ## One question to GitHub. Any failure becomes emptiness.
  try: http.getContent(Base & path).parseJson
  except CatchableError: newJNull()

# Tidy field access, safe against nil and wrong type.
func num(n: JsonNode, k: string): int = n{k}.getInt(0)
func str(n: JsonNode, k: string): string = n{k}.getStr("")
func arrLen(n: JsonNode, k: string): int =
  let v = n{k}
  if not v.isNil and v.kind == JArray: v.len else: 0

# ======================== DAEMON ==================================
proc gather() =
  createDir(home)
  let http = newHttpClient(headers = newHttpHeaders({
    "Authorization": "Bearer " & readToken(),
    "Accept": "application/vnd.github+json",
    "User-Agent": "muninn"}))
  defer: http.close()

  # default to the token's own user when MUNINN_USER is unset
  let user = if userCfg.len > 0: userCfg else: http.ask("user").str("login")

  let merged  = http.ask(&"search/issues?q=author:{user}+type:pr+is:merged&sort=updated&per_page=5")
  let openPRs = http.ask(&"search/issues?q=author:{user}+type:pr+is:open&per_page=10")
  let repos   = http.ask(&"users/{user}/repos?per_page=100&sort=updated")
  let notifs  = http.ask("notifications?per_page=50")
  let me      = http.ask(&"users/{user}")

  let mergedTotal = merged.num("total_count")
  let openTotal   = openPRs.num("total_count")
  let notifCount  = (if notifs.kind == JArray: notifs.len else: 0)
  let followers   = me.num("followers")
  var newest = "—"
  if merged.kind == JObject and merged{"items"}.len > 0:
    let top = merged["items"][0]
    newest = top.str("repository_url").rsplit("/repos/", 1)[^1] & "#" & $top.num("number")

  var stars, forks: int
  var foreign: seq[string]
  if repos.kind == JArray:
    for r in repos:
      stars += r.num("stargazers_count")
      forks += r.num("forks_count")
      if r.num("forks_count") > 0 or r.num("open_issues_count") > 0:
        let name  = r.str("name")
        let pulls = http.ask(&"repos/{user}/{name}/pulls?state=open&per_page=10")
        if pulls.kind == JArray:
          for p in pulls:
            let who = p{"user", "login"}.getStr("")
            if who.len > 0 and who != user:
              let t = p.str("title")
              foreign.add(&"{name}#{p.num(\"number\")} by @{who}: " & t[0 ..< min(50, t.len)])

  var was = newJObject()
  if fileExists(home / "state.json"):
    try: was = readFile(home / "state.json").parseJson
    except CatchableError: discard
  template grew(now: int, key: string): int =
    (if was.hasKey(key): now - was.num(key) else: 0)
  var prevForeign: seq[string]
  if was{"ext_prs"} != nil and was["ext_prs"].kind == JArray:
    for e in was["ext_prs"]: prevForeign.add(e.getStr(""))
  var fresh: seq[string]
  for p in foreign:
    if p notin prevForeign: fresh.add(p)

  var flags: seq[string]
  let dM = grew(mergedTotal, "merged_total")
  let dS = grew(stars, "stars")
  let dF = grew(forks, "forks")
  let dN = grew(notifCount, "notifs")
  let dFo = grew(followers, "followers")
  if dM > 0: flags.add(&"merge +{dM} (latest: {newest})")
  if dS > 0: flags.add(&"stars +{dS}")
  if dF > 0: flags.add(&"forks +{dF}")
  if fresh.len > 0: flags.add(&"foreign pr: {fresh.len}")
  if dN > 0: flags.add(&"notifications +{dN}")
  if dFo > 0: flags.add(&"followers +{dFo}")
  let headline = if flags.len > 0: flags.join(" · ") else: "no change since last run"

  var lines = @[
    "# muninn — digest", "", "**" & headline & "**", "",
    &"- merged PRs total: {mergedTotal} (latest: {newest})",
    &"- open PRs: {openTotal}",
    &"- stars: {stars} · forks: {forks}",
    &"- notifications: {notifCount} · followers: {followers}",
    &"- foreign open PRs: {foreign.len}"]
  for p in foreign: lines.add "    • " & p
  writeFile(home / "digest.md", lines.join("\n") & "\n")

  writeFile(home / "state.json", (%* {
    "merged_total": mergedTotal, "newest_merge": newest, "open_total": openTotal,
    "stars": stars, "forks": forks, "notifs": notifCount, "followers": followers,
    "ext_prs": foreign}).pretty)
  writeFile(home / "heartbeat", "")
  echo headline

# ======================== CLI =====================================
proc status() =
  var s = newJObject()
  if fileExists(home / "state.json"):
    try: s = readFile(home / "state.json").parseJson
    except CatchableError: discard
  var hb = "—"
  if fileExists(home / "heartbeat"):
    hb = getLastModificationTime(home / "heartbeat").local.format("yyyy-MM-dd HH:mm")

  proc r(sect, metric, value: string, note = ""): string =
    result = "   " & alignLeft(sect, 14) & alignLeft(metric, 15) & align(value, 3)
    if note.len > 0: result &= "   " & note

  let rule = "  " & repeat("─", 48)
  echo ""
  echo rule
  echo "  " & Title
  echo "  " & Quote & "   — Grímnismál 20"
  echo rule
  echo r("pr", "merged", $s.num("merged_total"), s.str("newest_merge"))
  echo r("", "open", $s.num("open_total"))
  echo r("repositories", "stars", $s.num("stars"))
  echo r("", "forks", $s.num("forks"))
  echo r("", "foreign pr", $s.arrLen("ext_prs"))
  echo r("incoming", "notifications", $s.num("notifs"))
  echo r("", "followers", $s.num("followers"))
  echo ""
  echo "  snapshot " & hb
  echo ""

when isMainModule:
  if paramCount() >= 1 and paramStr(1) in ["status", "show"]: status()
  else: gather()
