# Totem

Lives inside an Elixir app and owns its code: it changes the running app in
place, watches it, and takes it back when a change goes wrong. One library
for any app, Burrow's included.

## In every app: the runtime

```elixir
Totem.current()
#=> %{tree: %{path => hash}, hash: "9f3c…", label: "main #12"}

Totem.apply([{"lib/app/x.ex", from_hash, new_source}, {"lib/old.ex", from_hash, :deleted}],
  label: "main #13", watch: 15_000)
#=> {:ok, %{mode: "hot", output: "…", label: "main #13"}}
```

* Each file names the hash it must have now (nil: it must not exist), so two
  writers never overwrite each other: `{:error, {:conflict, paths}}`.
* A change loads hot (recompiled in place, processes keep their state), warm
  (config or application.ex: the app restarts inside the running node) or
  cold (mix.exs: written, waits for a restart).
* A failed load puts the previous files back. With `:watch`, so does an error
  the app logs in that window that it hadn't logged before:
  `{:error, {:reverted, mode, errors}}`.
* No history in the app: the code is its files. `.totem/` holds a cache of
  contents sent ahead of a change and the label of the last one.

Errors (with a fingerprint), request counts and the observer figures come
from `Totem.Monitor`, from boot on.

## An app that is its own origin

With `config :totem, origin: true` (or `TOTEM_ORIGIN=1`), say a dev app that
agents change directly, Totem also keeps the app's history (`Totem.Repo` in
`.totem/repo`: plain files, no database) and takes drafts (`Totem.Origin`):

1. an agent writes a draft against a change of main
2. Totem builds and tests it in a scratch directory (`Totem.Check`)
3. landing merges it onto main, line by line where others changed the same
   file (`Totem.Merge`), and loads it with a watch window; if the app takes
   it badly it is reverted on main too, so main is what runs

## Reaching it

* **Dialing out** (`Totem.Link`): set `TOTEM_LINK` to a Unix socket and
  Totem dials it, reports errors, stats and readiness, and takes commands
  (`Totem.Commands`). Nothing listens inside the app. Burrow runs apps this way.
* **HTTP and MCP** (`Totem.Plug`, for apps with Plug): `plug Totem.Plug` in
  the endpoint, before `Plug.Parsers`, and a `TOTEM_TOKEN`. It serves
  `/_totem/...` and an MCP server at `/_totem/mcp`: every app lets an agent
  read and search its code and see its errors; an origin also takes drafts.
* **From a terminal**:
  * `mix totem.clone <url>/_totem dir` checks the code out
  * `mix totem.push` sends what changed as a draft, checked and landed
  * `mix totem.promote <dev>/_totem <prod>/_totem [change]` makes prod run
    one of dev's changes, whole: only the contents prod lacks, applied against
    what it runs now, with a watch window

Totem has no dependencies on the rest of this repo, so apps outside it can
use it straight from GitHub:

```elixir
{:totem, github: "askasp/burrow", sparse: "totem"}
```
