# Totem

Lives inside an Elixir app. It is becoming one library for any app, Burrow
included:

* knows the app's code: trees of content-addressed blobs (`Totem.Tree`,
  `Totem.Blob`), diffs (`Totem.Diff`) and what isn't code (`Totem.Ignore`)
* hot-loads new code into the running node, or restarts when it must
* reports the node's health: observer figures, processes, errors, requests
* talks over an API and an MCP, or dials out to a server such as Peon

## Using it

```elixir
Totem.current()   # the version this node runs: %{version: 12, tree: %{path => hash}, ...}
Totem.read("lib/app/x.ex")
Totem.apply(%{base: 12, files: [{"lib/app/x.ex", source}, {"lib/old.ex", :deleted}]})
Totem.rollback(11)
Totem.archive()   # the current code as a .tar.gz
```

A change loads hot (recompiled in place, processes keep their state), warm
(config or application.ex: the app restarts inside the running node) or cold
(mix.exs: written, waits for a restart). A failed load puts the previous
code back. See `Totem` for the details.

## How it stores code

Plain files in `.totem/`, the way git stores objects: one compressed file
per distinct content, named by its sha256, and one small JSON file per
version holding its tree (`path => hash`). No database, so any app can add
it, and every write is crash-safe (written aside, renamed into place).

Peon keeps the full history; Totem keeps what the node runs and the
versions before it, with the same hashes, so a deploy sends only the
contents Totem is missing (`Totem.missing/1`).

## Reaching it

* **Dialing out** (`Totem.Link`): set `TOTEM_LINK` to a Unix socket and
  Totem dials it, reports errors, stats and readiness, and takes commands
  (`Totem.Commands`). Nothing listens inside the app. Peon runs apps this way.
* **HTTP and MCP** (`Totem.Plug`, for apps with Plug): `plug Totem.Plug` in
  the endpoint, before `Plug.Parsers`, and a `TOTEM_TOKEN`. It serves
  `/_totem/...` and an MCP server at `/_totem/mcp`, so an agent can read,
  search and change the running code with no checkout.
* **From a terminal**: `mix totem.clone <url>/_totem dir`, edit, `mix
  totem.push` (sends only what changed; the app loads it), `mix totem.pull`.

Errors, request counts and the observer figures come from `Totem.Monitor`,
which runs from boot, so errors while the app starts are caught too.

Totem has no dependencies on the rest of this repo, so apps outside it can
use it straight from GitHub (no tag yet; the first one comes with the
first release):

```elixir
{:totem, github: "askasp/burrow", sparse: "totem", tag: "totem-v0.1.0"}
```
