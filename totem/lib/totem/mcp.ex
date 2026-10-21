defmodule Totem.MCP do
  @moduledoc """
  The app as an MCP server (JSON-RPC 2.0), served over HTTP by `Totem.Plug`
  at `<mount>/mcp`. Every node lets an agent read its code and look at what
  it does. A node that is its own origin (`Totem.Origin`) also takes changes:
  the agent writes a draft, checks it, and lands it, which loads it into the
  running app.
  """

  alias Totem.{Commands, Origin}

  @protocol_version "2025-06-18"

  @read_tools [
    %{
      name: "status",
      description:
        "What the app runs (the label of its last change), how many files it has, and the latest errors.",
      inputSchema: %{type: "object", properties: %{}}
    },
    %{
      name: "list_files",
      description: "The app's files, optionally only those matching a glob (`lib/**`).",
      inputSchema: %{type: "object", properties: %{glob: %{type: "string"}}}
    },
    %{
      name: "read_file",
      description: "A file's content as the app runs it.",
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

  @draft_file %{
    type: "object",
    properties: %{
      path: %{type: "string"},
      content: %{type: "string", description: "The file's new content"},
      deleted: %{type: "boolean", description: "true to delete the file"}
    },
    required: ["path"]
  }

  @origin_tools [
    %{
      name: "write_draft",
      description: """
      Puts your change as a draft: the files you change, with their whole new content. \
      It doesn't run yet. Use your own id (the same one each time replaces the draft) and \
      the change you read the files at (`base`, from `log`; default main).\
      """,
      inputSchema: %{
        type: "object",
        properties: %{
          id: %{type: "string"},
          base: %{type: "integer"},
          intent: %{type: "string", description: "One sentence: what the change does"},
          files: %{type: "array", items: @draft_file}
        },
        required: ["id", "files", "intent"]
      }
    },
    %{
      name: "check_draft",
      description:
        "Builds the draft (warnings as errors) and runs the tests, away from the running app.",
      inputSchema: %{type: "object", properties: %{id: %{type: "string"}}, required: ["id"]}
    },
    %{
      name: "land_draft",
      description: """
      Merges the draft onto main and loads it into the running app. If the app logs a \
      new error right after, it is undone and you get the error. Edits to the same \
      lines as a change since your base come back as a conflict: read and write again.\
      """,
      inputSchema: %{type: "object", properties: %{id: %{type: "string"}}, required: ["id"]}
    },
    %{
      name: "revert",
      description: "Undoes a change on main, in the running app too.",
      inputSchema: %{
        type: "object",
        properties: %{change: %{type: "integer"}},
        required: ["change"]
      }
    },
    %{
      name: "log",
      description: "Main's changes, newest first: id, intent, who, files.",
      inputSchema: %{type: "object", properties: %{limit: %{type: "integer"}}}
    }
  ]

  @doc "The tools this node offers."
  def tools, do: if(Origin.enabled?(), do: @read_tools ++ @origin_tools, else: @read_tools)

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
  defp call("tools/list", _params), do: {:ok, %{tools: tools()}}

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
     %{
       "label" => current["label"],
       "files" => map_size(current["tree"]),
       "errors" => Enum.take(errors, 5)
     }}
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

  defp tool(name, args) when name in ~w(errors processes stats log revert),
    do: Commands.run(name, args)

  defp tool("write_draft", args), do: Commands.run("draft_write", args)
  defp tool("check_draft", args), do: Commands.run("draft_check", args)
  defp tool("land_draft", args), do: Commands.run("land", args)
  defp tool(name, _args), do: {:error, "unknown tool: #{name}"}

  defp text(text) when is_binary(text), do: text
  defp text(other), do: JSON.encode!(other)
end
