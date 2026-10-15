# Burrow

Burrow is a SaaS where you sign up, create projects, and build each one by chatting with an AI agent. Every project gets its own **Peon**: code history, policy, sandboxed checks and live previews. The agent is **opencode**, running on your own AI logins and subscriptions.

```
Burrow (burrow/)         users, projects, AI login (opencode credentials per user)
 └─ Peon (peon/)         one per project: code store, policy, checks, chats
     └─ per chat         a workspace on disk + two sandbox containers on a private network:
         ├─ agent        opencode serve: edits the workspace with its own tools, runs mix test
         └─ preview      the app in dev mode on the same workspace (http://preview:4000)
```

A change flows like this, with no queue in front of main:

1. You chat in Peon. The chat is an opencode session; the agent edits the chat's workspace, and the preview reloads. Many chats work in parallel, each in its own workspace; when main moves, every workspace follows it.
2. The agent calls Peon's MCP tool `submit_changeset`. Peon diffs the workspace against its base, checks policy (forbidden paths, migration rules, secrets) and stores an immutable changeset.
3. Peon compiles (warnings as errors) and format-checks it in a clean sandbox, several at a time. When that passes it **lands on main right away**, rebased onto main's tip; changes to mix.exs, config and auth wait for your **Land** click instead.
4. Main's tests run after landing. When they fail, Peon bisects to the changeset that broke them and tells its chat to fix forward (or you click **revert**).
5. Main's tested tip is **hot-loaded into the running staging app**: the attacher, a hidden Erlang node next to the app, recompiles inside it, rebuilds assets and runs new migrations. mix.exs or config changes restart the container instead. Then a health window: `/health` and `/` must answer and no new error may be logged, or Peon rolls back to the last healthy changeset.
6. **Promote** sends a healthy staging changeset to prod the same way (or set the project setting `auto_promote: true`).
7. Errors from staging and prod arrive through the attacher with stacktraces and become incidents. A new incident opens a chat that is asked to fix it (`auto_fix`, default on); the incident resolves when that fix is deployed.

Keyboard: `ctrl+b`, then a key (tmux style, from Beamcode). `ctrl+b ?` lists them.

```
template/       the app every project starts from (Phoenix + LiveView + SQLite + email/password auth)
peon_core/      shared pure code: blobs, trees, diffs, policy rules, ignore rules
images/         sandbox image for checks, previews and agents
tools/          generator for Phoenix apps with email/password auth
```

## Run it locally

Requires Elixir 1.18 / OTP 27, Docker, and opencode (v2) logged in to at least one provider.

1. Build the sandbox image and the Peon release (repeat the release build after changing Peon):
   ```
   docker build -t burrow/elixir-dev:1 images/elixir-dev
   cd peon && MIX_ENV=prod mix do compile + assets.deploy + release --overwrite && cd ..
   ```
2. Start Burrow:
   ```
   cd burrow && mix setup && mix phx.server
   ```
3. Open http://localhost:4000 and register.
4. Open **AI login** and connect a provider: an API key, "Sign in with ChatGPT", or (local mode) **Use this computer's opencode logins**. Pick the model for your Peons.
5. Create a project, click **Open**, and describe what to build.

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
| Burrow | 4000 |
| Peon for project N | 4100 + N |
| Previews for project N | 5000 + 10·N … +7 |
| Staging, prod for project N | 5000 + 10·N + 8, + 9 |

Data lives in `data/` (gitignored); each user's opencode logins are in `data/burrow/users/<id>/opencode`. Delete `data/` to start over.

## Not built yet

- The host agent: Burrow starts Peons as local OS processes instead of in containers.
- Caddy and DNS, the CLI (`peon.checkout` / `peon.submit`).
