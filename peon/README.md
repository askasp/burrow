# Peon

The engine behind each Burrow project: its code store, policy, sandboxed
checks, chats (an opencode agent and a dev preview per chat) and its staging
and prod environments. Burrow runs one `Peon.Instance` per project inside its
own BEAM and draws the workspace; Peon has no web layer of its own.

* `Peon.Instance` - one project's tree, its database and names
* `Peon.Store`, `Peon.Checks`, `Peon.Verifier`, `Peon.Ship` - from a chat's changeset to main
* `Peon.Chat` - one chat's workspace, agent and preview containers
* `Peon.Env` - staging and prod, deployed through Totem (`totem/`), which runs inside the app and dials Peon

Run the tests with `mix test` (Docker is needed for none of them).
