defmodule Burrow.OpenCodeTest do
  # Writes to the shared data directory, which every chat's config reads.
  use ExUnit.Case, async: false

  alias Burrow.OpenCode

  test "this computer's model servers come from opencode-providers.json, else none" do
    path = Path.join(Application.fetch_env!(:burrow, :data_dir), "opencode-providers.json")
    File.mkdir_p!(Path.dirname(path))
    on_exit(fn -> File.rm(path) end)

    assert OpenCode.custom_providers() == %{}

    local = %{
      "local" => %{
        "npm" => "@ai-sdk/openai-compatible",
        "options" => %{"baseURL" => "http://localhost:8080/v1"},
        "models" => %{"qwen" => %{"name" => "Qwen"}}
      }
    }

    File.write!(path, Jason.encode!(local))
    assert OpenCode.custom_providers() == local
  end
end
