defmodule Peon.Source do
  @moduledoc """
  Where this Peon's code comes from. By default it is Peon's own store, seeded
  from the template: changesets land on main and deploy to staging and prod.

  A repo project (`Peon.Instance` `:repo`) works on an existing git repo instead. Each
  chat gets a git checkout (`Peon.Git`), the repo's preview pack runs it on
  the host (`Peon.PreviewPack`, `Peon.HostPreview`), and there is no store,
  no checks and no envs.
  """

  @doc "`%{url, branch}` of the repo, or nil for a store project."
  def repo, do: Peon.Instance.fetch!(:repo)

  def repo?, do: repo() != nil
end
