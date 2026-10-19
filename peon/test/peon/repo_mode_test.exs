defmodule Peon.RepoModeTest do
  use Peon.DataCase, async: false

  alias Peon.Agent.{Prompt, Tools}
  alias Peon.{PreviewPack, Project, Repo}

  setup do
    previous = Application.get_env(:peon, :repo)
    Application.put_env(:peon, :repo, %{url: "https://github.com/a/b.git", branch: "main"})
    on_exit(fn -> Application.put_env(:peon, :repo, previous) end)
    Repo.insert!(%Project{slug: "amino", name: "Amino"})
    :ok
  end

  test "the agent only gets the tools that make sense without a store" do
    assert Enum.map(Tools.specs(), & &1.name) ==
             ~w(submit_changeset restart_preview secrets request_secret)

    assert Enum.find(Tools.specs(), &(&1.name == "submit_changeset")).description =~
             "pull request"

    assert {"Unknown tool" <> _, true} = Tools.call("restore", %{"paths" => ["a"]}, "c")
  end

  test "the instructions say where the preview runs, or how to add one" do
    pack = %PreviewPack{ports: ["app", "api"], frame: "app", start: "docker compose up -d"}

    text =
      Prompt.repo_instructions(%{
        branch: "peon/ab12",
        pack: pack,
        ports: %{"app" => 5011, "api" => 5012},
        url: &"https://p-#{&1}.example.com"
      })

    assert text =~ "peon/ab12"
    assert text =~ "api: https://p-5012.example.com (or http://host.docker.internal:5012)"
    assert text =~ "/peon/preview.log"
    assert text =~ "peon_submit_changeset"
    assert text =~ "Only when the user asks you to submit"

    text = Prompt.repo_instructions(%{branch: "peon/ab12", pack: :none, ports: %{}, url: nil})
    assert text =~ "no `.peon/preview.json` yet"
  end
end
