# muninn

> *Huginn ok Muninn fljúga hverjan dag …* — **Grímnismál 20**
>
> Muninn — ворон Одина по имени «Память»: каждый день облетает мир
> и возвращается с вестями. Этот маленький демон делает то же с
> твоим GitHub.

A tiny, dependency-free GitHub activity watcher written in
[Nim](https://nim-lang.org). One small native binary, no runtime
deps beyond libc + (dlopen'd) libssl. Two modes: a quiet daemon that
polls GitHub and remembers the delta, and a CLI that prints a clean
table from the last snapshot — instantly, offline.

Крошечный наблюдатель GitHub-активности на чистом Nim. Один нативный
бинарь, никаких внешних процессов. Демон опрашивает GitHub и помнит
дельту; CLI рисует таблицу из последнего снимка — мгновенно, без сети.

## What it watches / Что отслеживает

Merged & open PRs · stars · forks · **foreign PRs to your repos** — each
with a delta (`new`) against the previous run. (The daemon's digest also
flags new notifications for a bot/hook.)

## Build / Сборка

```sh
nim c -d:release -d:ssl --hints:off muninn.nim
```

## Use / Использование

```sh
muninn            # daemon: poll GitHub, write snapshot + digest
muninn status     # CLI: render the table from the last snapshot
```

```
  ────────────────────────────────────────────────
                 M U N I N N
   »Doch bangt mir mehr um Munin.« Grímnismál 20
  ────────────────────────────────────────────────
   pull requests
  ────────────────────────────────────────────────

     merged             total       11
                        new          0
     open               total        0

   repositories
  ────────────────────────────────────────────────

     stars              total        3
     forks              total        0
     foreign pr         total        0

  ────────────────────────────────────────────────
   last looked: 17m ago


  ────────────────────────────────────────────────
```

## Configure / Настройка (env)

| Variable | Default | Meaning |
|---|---|---|
| `MUNINN_USER`  | the token's owner | whose GitHub to watch |
| `MUNINN_HOME`  | `~/.config/muninn` | where snapshot/digest live |
| `GITHUB_TOKEN` | from the GitHub CLI | API token (never logged) |

## Deploy as a daemon / Демон (systemd)

```ini
# ~/.config/systemd/user/muninn.service
[Service]
Type=oneshot
Environment=MUNINN_USER=%u
ExecStart=%h/.local/bin/muninn

# muninn.timer → OnUnitActiveSec=8h
```

## Принципы / Principles

- the token is read from config and **never** written to a log;
- any network error becomes emptiness — the angel never crashes;
- writes only to its own dir, reads only GitHub.

## License

MIT © 2026 Aleksei Rybnikov

*Спасибо Василию ([@Balans097](https://github.com/Balans097)) — за Nim
и за письмо, с которого всё началось.*
