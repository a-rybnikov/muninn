## ╔══════════════════════════════════════════════════════════════╗
## ║  muninn — тихий ангел, наблюдатель GitHub-активности.          ║
## ║                                                                ║
## ║  «Huginn ok Muninn fljúga hverjan dag …» — Grímnismál 20.       ║
## ║  Мунин — ворон Одина по имени «Память»: облетает мир и          ║
## ║  возвращается с вестями. Этот демон делает то же с GitHub.     ║
## ╚══════════════════════════════════════════════════════════════╝
##
## Чистый Nim: std/httpclient + std/json. Внешних процессов нет.
##
## Два режима одного бинаря:
##   muninn           — демон: спросить GitHub, записать дайджест+снимок;
##   muninn status    — нарисовать таблицу из последнего снимка (без сети).
##
## Следит: PR (смёрджено/открыто), звёзды, форки, чужие PR,
##         уведомления, подписчики. Сравнивает с прошлым разом (дельта).
##
## Настройка через окружение:
##   MUNINN_USER  — чей GitHub наблюдать (по умолч. a-rybnikov);
##   MUNINN_HOME  — куда писать снимок/дайджест (по умолч. ~/.config/muninn);
##   GITHUB_TOKEN — токен; иначе берётся из ~/.config/gh/hosts.yml.
## Токен НИКОГДА не попадает в лог.
##
## Сборка:  nim c -d:release -d:ssl --hints:off muninn.nim

import std/[os, json, strutils, strformat, httpclient, unicode, times]

let
  user = getEnv("MUNINN_USER", "a-rybnikov")
  home = getEnv("MUNINN_HOME", getConfigDir() / "muninn")

const
  Base  = "https://api.github.com/"
  # подзаголовок (Эдда; можно заменить любой строкой)
  Quote = "«Der Gedanke fliegt aus, das Gedächtnis kehrt heim.»"

# ── Токен: из окружения, иначе из конфига gh. В лог не пишем. ───────
proc readToken(): string =
  result = getEnv("GITHUB_TOKEN")
  if result.len > 0: return
  let hosts = getHomeDir() / ".config" / "gh" / "hosts.yml"
  if fileExists(hosts):
    for line in lines(hosts):
      if "oauth_token:" in line:
        return line.split("oauth_token:", 1)[1].strip()

# ── Один вопрос к GitHub. На любой сбой — пустота. ─────────────────
proc ask(http: HttpClient, path: string): JsonNode =
  try: http.getContent(Base & path).parseJson
  except CatchableError: newJNull()

# ── Опрятный доступ к полю (безопасен к nil и чужому типу) ─────────
func num(n: JsonNode, k: string): int = n{k}.getInt(0)
func str(n: JsonNode, k: string): string = n{k}.getStr("")

# ════════════════════════ ДЕМОН ═══════════════════════════════════
proc gather() =
  createDir(home)
  let http = newHttpClient(headers = newHttpHeaders({
    "Authorization": "Bearer " & readToken(),
    "Accept": "application/vnd.github+json",
    "User-Agent": "muninn"}))
  defer: http.close()

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
    let n = top.num("number")
    newest = top.str("repository_url").rsplit("/repos/", 1)[^1] & "#" & $n

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
              let pn = p.num("number")
              foreign.add(&"{name}#{pn} от @{who}: " & t[0 ..< min(50, t.len)])

  var was = newJObject()
  if fileExists(home / "state.json"):
    try: was = readFile(home / "state.json").parseJson
    except CatchableError: discard
  template grew(now: int, key: string): int =
    (if was.hasKey(key): now - was.num(key) else: 0)
  var prevForeign: seq[string]
  if was{"ext_prs"}.kind == JArray:
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
  if dM > 0: flags.add(&"🎉 +{dM} НОВЫЙ мёрдж (последний: {newest})")
  if dS > 0: flags.add(&"⭐ +{dS} новых звёзд")
  if dF > 0: flags.add(&"🔱 +{dF} новых форков")
  if fresh.len > 0: flags.add(&"📥 ЧУЖОЙ PR: {fresh.len}")
  if dN > 0: flags.add(&"✉ +{dN} уведомлений")
  if dFo > 0: flags.add(&"👤 +{dFo} подписчиков")
  let headline = if flags.len > 0: flags.join(" · ") else: "без изменений с прошлого прогона"

  var lines = @[
    "# muninn — дайджест", "", "**" & headline & "**", "",
    &"- PR смёрджено всего: {mergedTotal} (последний: {newest})",
    &"- PR открыто: {openTotal}",
    &"- звёзды: {stars} · форки: {forks}",
    &"- уведомления: {notifCount} · подписчики: {followers}",
    &"- чужие открытые PR: {foreign.len}"]
  for p in foreign: lines.add "    • " & p
  writeFile(home / "digest.md", lines.join("\n") & "\n")

  writeFile(home / "state.json", (%* {
    "merged_total": mergedTotal, "newest_merge": newest, "open_total": openTotal,
    "stars": stars, "forks": forks, "notifs": notifCount, "followers": followers,
    "ext_prs": foreign}).pretty)
  writeFile(home / "heartbeat", "")
  echo headline

# ════════════════════════ CLI ═════════════════════════════════════
proc row(label, value: string, note = ""): string =
  # выравниваем по РУНАМ (кириллица в UTF-8 = 2 байта/символ)
  let pad = repeat(" ", max(0, 14 - label.runeLen))
  result = "    " & label & pad & align(value, 4)
  if note.len > 0: result &= "   " & note

proc status() =
  var s = newJObject()
  if fileExists(home / "state.json"):
    try: s = readFile(home / "state.json").parseJson
    except CatchableError: discard
  var hb = "—"
  if fileExists(home / "heartbeat"):
    hb = getLastModificationTime(home / "heartbeat").local.format("yyyy-MM-dd HH:mm")
  echo ""
  echo "  muninn"
  echo "  " & Quote
  echo "  " & repeat("─", 46)
  echo "   PR"
  echo row("смёрджено", $s.num("merged_total"), "последний: " & s.str("newest_merge"))
  echo row("открыто", $s.num("open_total"))
  echo "   репозитории"
  echo row("звёзды", $s.num("stars"))
  echo row("форки", $s.num("forks"))
  echo row("чужие PR", $(if s{"ext_prs"}.kind == JArray: s["ext_prs"].len else: 0))
  echo "   входящее"
  echo row("уведомления", $s.num("notifs"))
  echo row("подписчики", $s.num("followers"))
  echo ""
  echo "  снимок: " & hb
  echo ""

when isMainModule:
  if paramCount() >= 1 and paramStr(1) in ["status", "show"]: status()
  else: gather()
