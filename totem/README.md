# Totem

Lives inside an Elixir app. It is becoming one library for any app, Burrow
included:

* knows the app's code: trees of content-addressed blobs (`Totem.Tree`,
  `Totem.Blob`), diffs (`Totem.Diff`) and what isn't code (`Totem.Ignore`)
* hot-loads new code into the running node, or restarts when it must
* reports the node's health: observer figures, processes, errors, requests
* talks over an API and an MCP, or dials out to a server such as Peon

Today the probe (`priv/probe.exs`) is still loaded into apps by Peon with
`elixir -r`; it becomes Totem's own modules next.

Totem has no dependencies on the rest of this repo, so apps outside it can
use it straight from GitHub (no tag yet; the first one comes with the
first release):

```elixir
{:totem, github: "askasp/burrow", sparse: "totem", tag: "totem-v0.1.0"}
```
