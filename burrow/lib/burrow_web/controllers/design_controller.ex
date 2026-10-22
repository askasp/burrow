defmodule BurrowWeb.DesignController do
  @moduledoc """
  A chat's boards (`Burrow.Design`) for the workspace's Design view. They are
  the agent's own HTML and scripts, so they are served sandboxed: an origin
  of their own, out of reach of Burrow's pages and cookies. Sandboxed frames
  send no cookies, so the URL carries a signed token for the chat instead
  (`path/2`).

  A board tells the frame's parent about its script errors (`{board: "error",
  error}`), which the Design view shows as a board that didn't load.
  """

  use BurrowWeb, :controller

  alias Burrow.{Design, Projects}

  @salt "design"
  @max_age 7 * 24 * 3600

  @reporter String.trim(~S"""
            <script>addEventListener("error",function(e){if(e.message)parent.postMessage({board:"error",error:e.message.replace(/^Uncaught /,"")+(e.lineno?" ("+(e.filename||"").split("/").pop().split("?")[0]+":"+e.lineno+")":"")},"*")})</script>
            """)

  @doc "Where chat `chat_id` of project `project_id` serves its design/ folder, for a week."
  def path(project_id, chat_id),
    do: "/design/" <> Phoenix.Token.sign(BurrowWeb.Endpoint, @salt, {project_id, chat_id})

  def show(conn, %{"token" => token, "path" => [_ | _] = path}) do
    with {:ok, {project_id, chat_id}} <-
           Phoenix.Token.verify(BurrowWeb.Endpoint, @salt, token, max_age: @max_age),
         %{} = project <- Projects.get(project_id),
         {:ok, content} <- Design.read(project, chat_id, Path.join(path)) do
      type = MIME.from_path(List.last(path))
      text? = String.starts_with?(type, "text/")

      conn
      |> put_resp_content_type(type, if(text?, do: "utf-8"))
      |> put_resp_header(
        "content-security-policy",
        "sandbox allow-scripts allow-forms allow-popups; frame-ancestors 'self'"
      )
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("cache-control", "no-store")
      |> send_board(type, content)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")

  # Chunked, so the dev server's live reloader leaves the board as it is.
  defp send_board(conn, "text/html", html) do
    {:ok, conn} = conn |> send_chunked(200) |> chunk(report_errors(html))
    conn
  end

  defp send_board(conn, _type, content), do: send_resp(conn, 200, content)

  # Right after the doctype, on its line, so the board's line numbers stay.
  defp report_errors(html) do
    case Regex.run(~r/\A\s*<!doctype[^>]*>/i, html) do
      [doctype] -> doctype <> @reporter <> String.replace_prefix(html, doctype, "")
      nil -> @reporter <> html
    end
  end
end
