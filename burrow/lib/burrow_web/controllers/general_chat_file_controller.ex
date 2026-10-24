defmodule BurrowWeb.GeneralChatFileController do
  @moduledoc """
  The files sent with a general chat's messages (`Burrow.GeneralChats.files_dir/1`),
  for the thread. Only for the chat's own user.
  """

  use BurrowWeb, :controller

  alias Burrow.GeneralChats

  def show(conn, %{"id" => id, "name" => name}) do
    with %GeneralChats.Chat{} = chat <- GeneralChats.get(conn.assigns.current_scope.user.id, id),
         true <- name =~ ~r/\A[\w-]+\.(png|jpe?g|gif|webp|pdf|txt|md|csv|json)\z/,
         file = Path.join(GeneralChats.files_dir(chat), name),
         true <- File.regular?(file) do
      conn
      |> put_resp_content_type(MIME.from_path(name), nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "sandbox")
      |> put_resp_header("cache-control", "private, max-age=31536000, immutable")
      |> send_file(200, file)
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
