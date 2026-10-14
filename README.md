# Burrow

Burrow is a SaaS where you sign up, create projects, and build each one by chatting with an AI agent. Every project gets its own **Peon**: code history, policy, sandboxed checks and live previews. The agent is **opencode**, running on your own AI logins and subscriptions.

```
Burrow (burrow/)         users, projects, AI login (opencode credentials per user)
 └─ Peon (peon/)         one per project: code store, policy, checks, chats
     └─ per chat         a workspace on disk + two sandbox containers on a private network:
         ├─ agent        opencode serve: edits the workspace with its own tools, runs mix test
         └─ preview      the app in dev mode on the same workspace (http://preview:4000)
```

A change flows like this:

1. You chat in Peon. The chat is an opencode session; the agent edits the chat's workspace, and the preview reloads.
2. The agent calls Peon's MCP tool `submit_changeset`. Peon diffs the workspace against its base, checks policy (forbidden paths, migration rules, secrets) and stores an immutable changeset.
3. Peon compiles (warnings as errors), checks formatting and runs the tests in a clean sandbox, then returns the result to the agent.
4. You click **Accept to main**. Every other chat's workspace is rebased onto the new main.

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
| Previews for project N | 5000 + 10·N … +9 |

Data lives in `data/` (gitignored); each user's opencode logins are in `data/burrow/users/<id>/opencode`. Delete `data/` to start over.

## Not built yet

- Staging/prod environments and the Reloader (hot reload, health window, rollback).
- The host agent: Burrow starts Peons as local OS processes instead of in containers.
- Caddy and DNS, the CLI (`peon.checkout` / `peon.submit`).
