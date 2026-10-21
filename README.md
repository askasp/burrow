# Burrow

Burrow is a SaaS where you sign up, create projects, and build each one by chatting with an AI agent. Every project gets its own **Peon**: code history, policy, sandboxed checks and live previews. The agent is **opencode**, running on your own AI logins and subscriptions.

```
Burrow (burrow/)         one BEAM: users, projects, AI login, and every project's workspace
 └─ Peon (peon/)         one per project, inside Burrow: code store, policy, checks, chats, envs
     ├─ per chat         a workspace on disk + two sandbox containers on a private network:
     │   ├─ agent        opencode serve: edits the workspace with its own tools, runs mix test
     │   └─ preview      the app in dev mode on the same workspace (http://preview:4000)
     └─ staging, prod    a container each, the app in prod mode with Totem inside it
```

Peon is an engine library: each project's Peon is a supervision tree in Burrow's BEAM (`Peon.Instance`) with its own SQLite database, started by `Burrow.Cell`. App code never runs in Burrow; it runs in the containers.

A change flows like this, with no queue in front of main:

1. You chat in Peon. The chat is an opencode session; the agent edits the chat's workspace, and the preview reloads. Many chats work in parallel, each in its own workspace; when main moves, every workspace follows it.
2. The agent calls Peon's MCP tool `submit_changeset`. Peon diffs the workspace against its base, checks policy (forbidden paths, migration rules, secrets) and stores an immutable changeset.
3. Peon compiles (warnings as errors) and format-checks it in a clean sandbox, several at a time. When that passes it **lands on main right away**, rebased onto main's tip; changes to dependencies and config (mix.exs, mix.lock, config/) wait for your **Land** click instead.
4. Main's tests run after landing. When they fail, Peon bisects to the changeset that broke them and tells its chat to fix forward (or you click **revert**).
5. Main's tested tip is **hot-loaded into the running staging app**: Totem (`totem/`, a dependency of every app) dials Peon over a mounted Unix socket; Peon sends only the files that changed and Totem loads them in place: hot (processes keep their state), warm for config and application.ex (the app restarts inside its node), with new migrations and rebuilt assets. mix.exs changes restart the container instead. Then a health window: `/health` and `/` must answer and no new error may be logged, or Peon rolls back to the last healthy changeset.
6. **Promote** sends a healthy staging changeset to prod the same way (or set the project setting `auto_promote: true`).
7. Errors from staging and prod arrive through Totem with stacktraces and become incidents. A new incident opens a chat that is asked to fix it (`auto_fix`, default on); the incident resolves when that fix is deployed.

**Secrets** (API keys, tokens, the shared site password) live in Peon, never in the code: `ctrl+b k`, or the box that shows in a chat when the agent asks for one (MCP tool `request_secret`). The preview, staging and prod get them as environment variables and restart when one changes; the agent sees names only, and checks and tests get none.

**The workspace is home.** After login Burrow opens the workspace of the project you opened last; Burrow's own project list (account, teams, AI login) is one click away. On the left, the project rail lists every project you can open, each tile with a health bar (working, waiting on you, live, stopped) that each Peon broadcasts and every workspace redraws, without polling. The workspace is Burrow's own page (`/projects/<id>`), in the same live session as the project list. A project has up to four chats, shown as tabs; each chat is one changeset, and once it is merged its chat is done. New projects start live-only (merging puts a change live); "Add staging and prod" in the ⋯ menu adds the pipeline above. "Deploys and usage" shows each environment's version, prod's sessions, requests, p95, visitors, memory and errors, and the latest deploys.

**Projects from a git repo.** Give a project an https git URL when you create it and its Peon works on that repo instead of the template. Each chat gets a clone on branch `peon/<chat id>`. The repo's preview pack, `.peon/preview.json`, runs its own dev stack **on the host**, in that clone, so file-watching dev servers reload as the agent edits and nothing needs committing. There are no checks, envs or store: when the agent calls `submit_changeset`, Peon commits the clone, merges the repo's main branch in, runs the pack's optional `check` command, pushes `peon/<chat id>` and opens the chat's pull request (later submits update it); the PR shows next to the preview. Pushing and PRs need the secret `GITHUB_TOKEN`, a fine-grained token for that repo (Contents and Pull requests, read and write). Peon asks for it, keeps it from the preview and the agent, and runs git without the host's credentials. Pack format: `Peon.PreviewPack`.

```json
{"ports": ["app", "api"], "local_ports": ["db"], "frame": "app",
 "env": {"WEB_PORT": "{port.app}", "API_URL": "{url.api}", "COMPOSE_PROJECT_NAME": "{name}"},
 "start": "docker compose up -d --build", "stop": "docker compose down -v", "ready": "/"}
```

**Login.** A new project picks its app's login: user accounts (phx.gen.auth, email and password), one username and password for everyone (HTTP basic auth; Burrow hands them to Peon once and they become the secrets `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD`), or open. Basic and open apps are made without the accounts code at all: `Peon.Template` leaves out what the template marks `peon:accounts-only` / `peon:if-accounts`.

**Who can see an app** is one line in it: `<App>.SiteAccess.mode/0` is `:login` (with accounts), `:basic_auth`, `:shared_password` (the secret `SITE_PASSWORD`, asked at `/unlock`) or `:public`. Ask in the chat to switch.

Keyboard: `ctrl+b`, then a key (tmux style, from Beamcode). `ctrl+b ?` lists them.

```
template/       the app every project starts from (Phoenix + LiveView + SQLite, with or without email/password auth)
totem/          the in-app library, no deps on the rest of the repo: keeps the running code and loads changes into it (hot, warm or cold), reports errors and stats, dials Peon or serves HTTP/MCP
images/         sandbox image for checks, previews and agents
tools/          generator for Phoenix apps with email/password auth
```

## Run it locally

Requires Elixir 1.18 / OTP 27, Docker, and opencode (v2) logged in to at least one provider.

1. Build the sandbox image:
   ```
   docker build -t burrow/elixir-dev:1 images/elixir-dev
   ```
2. Start Burrow:
   ```
   cd burrow && mix setup && mix phx.server
   ```
3. Open http://localhost:4000 and register.
4. Open **AI login** and connect a provider: an API key, "Sign in with ChatGPT", or (local mode) **Use this computer's opencode logins**. Pick the model for your Peons.
5. Create a project and describe what to build.

To work in the terminal instead, **Open in opencode** in a chat shows the command that attaches the opencode TUI to the same session.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `BURROW_OPENCODE_MODEL` | `openai/gpt-6-sol` | Model for users who haven't picked one |
| `BURROW_OPENCODE_BIN` | `opencode` on PATH | opencode executable, also mounted into agent containers |
| `BURROW_LOCAL_LOGIN_IMPORT` | `true` in dev | Show "Use this computer's opencode logins" |

## Ports (local mode)

| What | Port |
|---|---|
| Burrow, with every project's workspace | 4000 |
| Previews for project N | 21000 + 50·N … +47 (a repo project: all 50) |
| Staging, prod for project N | 21000 + 50·N + 48, + 49 |

Projects made before 2026-10-20 keep their 5000 + 10·N block. On the public tunnel, `peon-<port>.<domain>` reaches any of these ports through a small host-to-port router (ansible role `burrow`).

Data lives in `data/` (gitignored); each user's opencode logins are in `data/burrow/users/<id>/opencode`. Delete `data/` to start over.

## Not built yet

- The host agent: Burrow runs the containers on its own host.
- Caddy and DNS, the CLI (`peon.checkout` / `peon.submit`).
