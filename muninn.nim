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
  Base   = "https://api.github.com/"
  Title  = "M U N I N N"
  Quote  = "»Doch bangt mir mehr um Munin.«"   # Grimnismal 20
  Source = "Grímnismál 20"
  Width  = 50                                   # inner banner width

proc readToken(): string =
  ## from env, else from the GitHub CLI's config. Never logged.
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

func num(n: JsonNode, k: string): int = n{k}.getInt(0)
func str(n: JsonNode, k: string): string = n{k}.getStr("")
func list(n: JsonNode, k: string): seq[string] =
  let v = n{k}
  if not v.isNil and v.kind == JArray:
    for e in v: result.add e.getStr("")

# ======================== DAEMON ==================================
proc gather() =
  createDir(home)
  let http = newHttpClient(headers = newHttpHeaders({
    "Authorization": "Bearer " & readToken(),
    "Accept": "application/vnd.github+json",
    "User-Agent": "muninn"}))
  defer: http.close()

  let user = if userCfg.len > 0: userCfg else: http.ask("user").str("login")
  let merged  = http.ask(&"search/issues?q=author:{user}+type:pr+is:merged&sort=updated&per_page=10")
  let openPRs = http.ask(&"search/issues?q=author:{user}+type:pr+is:open&per_page=10")
  let repos   = http.ask(&"users/{user}/repos?per_page=100&sort=updated")
  let notifs  = http.ask("notifications?per_page=50")
  let me      = http.ask(&"users/{user}")

  let mergedTotal = merged.num("total_count")
  let openTotal   = openPRs.num("total_count")
  let notifCount  = (if notifs.kind == JArray: notifs.len else: 0)
  let followers   = me.num("followers")

  # recent merges as repo#num — so we can name what's NEW since last run
  var mergedRecent: seq[string]
  if merged.kind == JObject and merged{"items"} != nil:
    for it in merged["items"]:
      mergedRecent.add(it.str("repository_url").rsplit("/repos/", 1)[^1] & "#" & $it.num("number"))

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
              foreign.add(&"{name}#{p.num(\"number\")} by @{who}: " & t[0 ..< min(48, t.len)])

  # previous snapshot → deltas and new-lists
  var was = newJObject()
  if fileExists(home / "state.json"):
    try: was = readFile(home / "state.json").parseJson
    except CatchableError: discard
  template grew(now: int, key: string): int =
    (if was.hasKey(key): now - was.num(key) else: 0)
  func freshly(cur, prev: seq[string]): seq[string] =
    for x in cur:
      if x notin prev: result.add x
  # baseline on first run (no prior list) — don't flood with "new"
  let newMerges  = (if was.hasKey("merged_recent"): freshly(mergedRecent, was.list("merged_recent")) else: @[])
  let newForeign = (if was.hasKey("ext_prs"): freshly(foreign, was.list("ext_prs")) else: @[])

  let snap = %* {
    "merged_total": mergedTotal, "open_total": openTotal,
    "stars": stars, "forks": forks, "notifs": notifCount, "followers": followers,
    "merged_recent": mergedRecent, "ext_prs": foreign,
    "new_merges": newMerges, "new_foreign": newForeign,
    "d_stars": grew(stars, "stars"), "d_forks": grew(forks, "forks"),
    "d_notifs": grew(notifCount, "notifs"), "d_followers": grew(followers, "followers")}
  writeFile(home / "state.json", snap.pretty)

  # digest for the hook / bot (what's new since last poll)
  var flags: seq[string]
  if newMerges.len > 0: flags.add(&"merges +{newMerges.len}")
  if grew(stars, "stars") > 0: flags.add(&"stars +{grew(stars, \"stars\")}")
  if newForeign.len > 0: flags.add(&"foreign pr +{newForeign.len}")
  if grew(notifCount, "notifs") > 0: flags.add(&"notifications +{grew(notifCount, \"notifs\")}")
  if grew(followers, "followers") > 0: flags.add(&"followers +{grew(followers, \"followers\")}")
  let headline = if flags.len > 0: flags.join(" · ") else: "no change since last run"
  var d = @["# muninn — digest", "", "**" & headline & "**", ""]
  for m in newMerges: d.add "- merged: " & m
  for f in newForeign: d.add "- foreign: " & f
  writeFile(home / "digest.md", d.join("\n") & "\n")
  writeFile(home / "heartbeat", "")             # daemon run time (for the hook)
  echo headline

# ======================== CLI =====================================
proc kv(metric, tag, value: string): string =
  "     " & alignLeft(metric, 19) & alignLeft(tag, 11) & align(value, 3)
proc sub(name: string): string = repeat(" ", 24) & name

proc humanAgo(d: Duration): string =
  let days = d.inDays
  let hours = d.inHours mod 24
  let mins = d.inMinutes mod 60
  if days > 0: &"{days}d {hours}h ago"
  elif hours > 0: &"{hours}h {mins}m ago"
  else: &"{mins}m ago"

proc status() =
  var s = newJObject()
  if fileExists(home / "state.json"):
    try: s = readFile(home / "state.json").parseJson
    except CatchableError: discard

  let rule = "  " & repeat("─", Width - 2)
  echo ""
  echo rule
  echo repeat(" ", 17) & Title
  echo "   " & Quote & " " & Source
  echo rule

  let newMerges = s.list("new_merges")
  echo "   pr"
  echo kv("merged", "total", $s.num("merged_total"))
  echo kv("", "new", $newMerges.len)
  for m in newMerges: echo sub(m)
  echo kv("open", "total", $s.num("open_total"))
  echo ""
  echo "   repositories"
  echo kv("stars", "total", $s.num("stars"))
  if s.num("d_stars") > 0: echo kv("", "new", "+" & $s.num("d_stars"))
  echo kv("forks", "total", $s.num("forks"))
  if s.num("d_forks") > 0: echo kv("", "new", "+" & $s.num("d_forks"))
  let newForeign = s.list("new_foreign")
  echo kv("foreign pr", "total", $s.list("ext_prs").len)
  if newForeign.len > 0:
    echo kv("", "new", $newForeign.len)
    for f in newForeign: echo sub(f)
  echo ""
  echo "   incoming"
  echo kv("notifications", "total", $s.num("notifs"))
  if s.num("d_notifs") > 0: echo kv("", "new", "+" & $s.num("d_notifs"))
  echo kv("followers", "total", $s.num("followers"))
  if s.num("d_followers") > 0: echo kv("", "new", "+" & $s.num("d_followers"))

  # silent reminder: time since the user's PREVIOUS manual look.
  # separate file per channel (cli/gui/bot) — no clash with the daemon.
  let poke = home / "poke_cli"
  let note = if fileExists(poke):
               "you last looked " & humanAgo(now() - getLastModificationTime(poke).local)
             else: "first look"
  writeFile(poke, "")
  echo ""
  echo "   " & note
  echo ""

when isMainModule:
  if paramCount() >= 1 and paramStr(1) in ["status", "show"]: status()
  else: gather()
