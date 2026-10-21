defmodule Totem.MCP do
  @moduledoc """
  The app as an MCP server (JSON-RPC 2.0), served over HTTP by `Totem.Plug`
  at `<mount>/mcp`: an agent reads the running code, changes it (hot-loaded
  on the spot) and looks at what the app does, with no checkout.
  """

  alias Totem.Commands

  @protocol_version "2025-06-18"

  @file_schema %{
    type: "object",
    properties: %{
      path: %{type: "string"},
      content: %{type: "string", description: "The file's new content"},
      deleted: %{type: "boolean", description: "true to delete the file"}
    },
    required: ["path"]
  }

  @tools [
    %{
      name: "status",
      description:
        "The version the app runs (number, how it loaded, when), how many files it has, and the latest errors.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "list_files",
      description:
        "Paths in the running version, optionally only those matching a glob (`lib/**`).",
      inputSchema: %{type: "object", properties: %{glob: %{type: "string"}}}
    },
    %{
      name: "read_file",
      description: "A file's content in the running version.",
      inputSchema: %{type: "object", properties: %{path: %{type: "string"}}, required: ["path"]}
    },
    %{
      name: "search",
      description:
        "Lines matching a regex, as path:line, optionally only in files matching a glob.",
      inputSchema: %{
        type: "object",
        properties: %{pattern: %{type: "string"}, glob: %{type: "string"}},
        required: ["pattern"]
      }
    },
    %{
      name: "apply_changes",
      description: """
      Writes files and loads them into the running app. `base` is the version
      you read (from status); the change is refused when the app moved on since.
      Most files load hot (processes keep their state); config and
      application.ex restart the app inside its node; mix.exs needs a restart.
      When the code doesn't compile, nothing changes and you get the errors.
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          base: %{type: "integer"},
          files: %{type: "array", items: @file_schema},
          source: %{type: "string", description: "What the change is, kept with the version"}
        },
        required: ["base", "files"]
      }
    },
    %{
      name: "versions",
      description: "Earlier versions, newest first.",
      inputSchema: %{type: "object", properties: %{limit: %{type: "integer"}}}
    },
    %{
      name: "rollback",
      description: "Makes an earlier version's code run again (as a new version).",
      inputSchema: %{
        type: "object",
        properties: %{version: %{type: "integer"}},
        required: ["version"]
      }
    },
    %{
      name: "errors",
      description: "Errors the app logged lately, with stacktraces, newest first.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "processes",
      description: "The top processes by memory, reductions or message_queue_len.",
      inputSchema: %{
        type: "object",
        properties: %{
          sort: %{type: "string", enum: ["memory", "reductions", "message_queue_len"]},
          limit: %{type: "integer"}
        }
      }
    },
    %{
      name: "stats",
      description:
        "The node's figures (memory, processes, run queue, uptime) and request counts.",
      inputSchema: %{type: "object", properties: %{}}
    }
  ]

  @doc "Handles one JSON-RPC message. Returns a response map, or nil for notifications."
  @spec handle(map()) :: map() | nil
  def handle(%{"method" => method} = request) do
    case call(method, request["params"] || %{}) do
      _ when not is_map_key(request, "id") ->
        nil

      {:ok, result} ->
        %{jsonrpc: "2.0", id: request["id"], result: result}

      {:error, code, message} ->
        %{jsonrpc: "2.0", id: request["id"], error: %{code: code, message: message}}
    end
  end

  def handle(request),
    do: %{jsonrpc: "2.0", id: request["id"], error: %{code: -32600, message: "invalid request"}}

  defp call("initialize", params) do
    {:ok,
     %{
       protocolVersion: params["protocolVersion"] || @protocol_version,
       capabilities: %{tools: %{listChanged: false}},
       serverInfo: %{name: "totem", version: to_string(Application.spec(:totem, :vsn))}
     }}
  end

  defp call("ping", _params), do: {:ok, %{}}
  defp call("tools/list", _params), do: {:ok, %{tools: @tools}}

  defp call("tools/call", %{"name" => name} = params) do
    case tool(name, params["arguments"] || %{}) do
      {:ok, result} -> {:ok, %{content: [%{type: "text", text: text(result)}], isError: false}}
      {:error, error} -> {:ok, %{content: [%{type: "text", text: text(error)}], isError: true}}
    end
  end

  defp call("notifications/" <> _, _params), do: {:ok, nil}
  defp call(method, _params), do: {:error, -32601, "method not found: #{method}"}

  defp tool("status", _args) do
    {:ok, current} = Commands.run("current")
    {:ok, errors} = Commands.run("errors")

    {:ok,
     current
     |> Map.drop(["tree"])
     |> Map.put("files", map_size(current["tree"]))
     |> Map.put("errors", Enum.take(errors, 5))}
  end

  defp tool("list_files", args), do: Commands.run("list", args)

  defp tool("read_file", args) do
    with {:ok, file} <- Commands.run("read", args),
         do:
           {:ok, file["content"] || "(binary, #{byte_size(file["content_base64"])} bytes base64)"}
  end

  defp tool("search", args) do
    with {:ok, matches} <- Commands.run("search", args),
         do: {:ok, Enum.map_join(matches, "\n", &"#{&1["path"]}:#{&1["line"]}: #{&1["text"]}")}
  end

  defp tool("apply_changes", args),
    do: Commands.run("apply", Map.put_new(args, "source", "mcp"))

  defp tool("versions", args), do: Commands.run("versions", args)
  defp tool("rollback", args), do: Commands.run("rollback", args)
  defp tool("errors", args), do: Commands.run("errors", args)
  defp tool("processes", args), do: Commands.run("processes", args)
  defp tool("stats", args), do: Commands.run("stats", args)
  defp tool(name, _args), do: {:error, "unknown tool: #{name}"}

  defp text(text) when is_binary(text), do: text
  defp text(other), do: JSON.encode!(other)
end
