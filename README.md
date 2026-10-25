# Burrow

Burrow is a SaaS where you sign up, create projects, and build each one by chatting with **Peon**, an AI agent (**opencode**, running on your own AI logins and subscriptions). Every app it builds has **Totem** inside it: the library that keeps the app's code, loads changes into the running app and watches it.

```
Burrow (burrow/)        one BEAM: users, projects, AI logins, the workspace, and per project:
 ├─ history             a Totem history (Totem.Repo, plain files): main, drafts, refs
 ├─ per chat            a checkout + two sandbox containers on a private network:
 │   ├─ agent           opencode serve: edits the checkout, runs mix test, Peon's MCP tools
 │   └─ preview         the app in dev mode on the same checkout (http://preview:4000)
 ├─ main check          a throwaway container per new main: tests, prod build, boot
 └─ prod (+ staging)    a container each, the app in prod mode with Totem inside it
totem/ (Totem)          the library in every app, and the history format above
```

App code never runs in Burrow; it runs in the containers. A project's data (chats, secrets, incidents, runs) is in Burrow's database; its code is in its Totem history.

A change goes live in five stages:

1. **Build.** You ask in a chat. Peon edits the chat's checkout and its dev preview reloads; Totem in the preview reports errors as they happen. Up to four chats work in parallel, each in its own checkout.
2. **Land.** Peon calls its MCP tool `submit_changeset`: Burrow checks policy (forbidden paths, migration rules, secrets), then compiles (warnings as errors), checks the formatting of the changed files and runs the tests, in the chat's own agent container. Passed, the chat's draft lands on main, merged line by line with what other chats landed; only the same lines changed on both sides go back to the chat.
3. **Check.** Every new main is tested, built and booted in prod mode in a throwaway container. When that fails, the newest change is taken out again and its chat told.
4. **Ship.** You press **Ship** (or turn on "ship automatically"). Prod's Totem gets only the files that changed and loads them into the running app: hot (processes keep their state), warm for config and application.ex (the app restarts inside its node), with new migrations and rebuilt assets; mix.exs restarts the container. Projects can add a **staging** in front of prod.
5. **Repair.** Totem watches for new errors right after loading and puts the previous code back by itself. Errors later on become incidents; a new incident opens a chat asked to fix it (`auto_fix`, default on), and it resolves when the fix is deployed.

**Secrets** (API keys, tokens, the shared site password) live in Burrow, never in the code: `ctrl+b k`, or the box that shows in a chat when the agent asks for one (MCP tool `request_secret`). Previews, staging and prod get them as environment variables and restart when one changes; the agent sees names only, and checks and tests get none.

**The workspace is home.** After login Burrow opens the workspace of the project you opened last; Burrow's own project list (account, teams, AI login) is one click away. On the left, the project rail lists every project you can open, each tile with a health bar (working, waiting on you, live, stopped) that every workspace redraws when something happens in a project, without polling. The workspace is Burrow's own page (`/projects/<id>`), in the same live session as the project list. A project has up to four chats, shown as tabs; each chat is one change, and once it is on main its chat is done. New projects have prod only (called live); "Add staging" in the ⋯ menu puts staging in front of it. "Deploys and usage" shows each environment's version, prod's sessions, requests, p95, visitors, memory and errors, and the latest deploys.

**Projects from a git repo.** Give a project an https git URL when you create it and Peon works on that repo instead of the template (`Burrow.GitRepo`, its own part of the code: same chats, agent and preview pane). Each chat gets a clone on branch `peon/<chat id>`. The repo's preview pack, `.peon/preview.json`, runs its own dev stack **on the host**, in that clone, so file-watching dev servers reload as the agent edits and nothing needs committing. There is no Totem history, no checks and no envs: when the agent calls `submit_changeset`, Burrow commits the clone, merges the repo's main branch in, runs the pack's optional `check` command, pushes `peon/<chat id>` and opens the chat's pull request (later submits update it); the PR shows next to the preview. Pushing and PRs need the secret `GITHUB_TOKEN`, a fine-grained token for that repo (Contents and Pull requests, read and write). Burrow asks for it, keeps it from the preview and the agent, and runs git without the host's credentials. Pack format: `Burrow.GitRepo.PreviewPack`.

```json
{"ports": ["app", "api"], "local_ports": ["db"], "frame": "app",
 "env": {"WEB_PORT": "{port.app}", "API_URL": "{url.api}", "COMPOSE_PROJECT_NAME": "{name}"},
 "start": "docker compose up -d --build", "stop": "docker compose down -v", "ready": "/"}
```

**Login.** A new project picks its app's login: user accounts (phx.gen.auth, email and password; the first account is the admin and adds the others at `/users/admin`, and "Allow sign-ups" lets anyone register too, `SiteAccess.signups?/0`), one username and password for everyone (HTTP basic auth; they become the secrets `BASIC_AUTH_USERNAME` and `BASIC_AUTH_PASSWORD`), or open. Basic and open apps are made without the accounts code at all: `Burrow.Template` leaves out what the template marks `peon:accounts-only` / `peon:if-accounts`.

**Who can see an app** is one line in it: `<App>.SiteAccess.mode/0` is `:login` (with accounts), `:basic_auth`, `:shared_password` (the secret `SITE_PASSWORD`, asked at `/unlock`) or `:public`. Ask in the chat to switch.

Keyboard: `ctrl+b`, then a key (tmux style, from Beamcode). `ctrl+b ?` lists them.

```
template/       the app every project starts from (Phoenix + LiveView + SQLite, with or without email/password auth)
burrow/         the platform (Phoenix): accounts, projects, chats, shipping, environments, the workspace
totem/          the in-app library, no deps on the rest of the repo: histories, 3-way merge, loading changes hot/warm/cold, health window, errors and stats, a link to Burrow or HTTP/MCP for agents (see totem/README.md)
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
4. Open **AI login** and connect a provider: an API key, "Sign in with ChatGPT", or (local mode) **Use this computer's opencode logins**. Pick the model Peon uses.
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

On the public tunnel, `peon-<port>.<domain>` reaches any of these ports through a small host-to-port router (ansible role `burrow`).

Data lives in `data/` (gitignored); each user's opencode logins are in `data/burrow/users/<id>/opencode`. Delete `data/` to start over.

## Not built yet

- The host agent: Burrow runs the containers on its own host.
- Burrow loading its own code through Totem.
