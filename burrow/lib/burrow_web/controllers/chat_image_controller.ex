defmodule BurrowWeb.ChatImageController do
  @moduledoc """
  The images sent with a chat's messages (`Burrow.Chat.images_dir/2`), for
  the thread. Only for users who can open the project.
  """

  use BurrowWeb, :controller

  alias Burrow.{Chat, Chats, Projects}

  @doc "Where chat `chat_id` of project `project_id` serves its images, `<path>/<name>`."
  def path(project_id, chat_id), do: "/projects/#{project_id}/c/#{chat_id}/images"

  def show(conn, %{"id" => id, "chat" => chat_id, "name" => name}) do
    with {project_id, ""} <- Integer.parse(id),
         true <- Projects.visible?(conn.assigns.current_scope, project_id),
         %{project_id: ^project_id} <- Chats.get(chat_id),
         true <- name =~ ~r/\A[\w-]+\.(png|jpe?g|gif|webp)\z/,
         file = Path.join(Chat.images_dir(Projects.get(project_id), chat_id), name),
         true <- File.regular?(file) do
      conn
      |> put_resp_content_type(MIME.from_path(name), nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_file(200, file)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
