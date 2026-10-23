defmodule BurrowWeb.ChatImageControllerTest do
  use BurrowWeb.ConnCase, async: false

  import Burrow.AccountsFixtures
  import Burrow.ProjectHelpers

  alias Burrow.Accounts.Scope
  alias Burrow.{Chat, Chats, Projects}

  @moduletag :tmp_dir

  setup :register_and_log_in_user

  setup %{user: user, tmp_dir: dir} do
    {:ok, project} = Projects.create(Scope.for_user(user), %{"name" => "App"})
    project = start_project!(project, dir)
    chat = Chats.create_empty(project.id, user.email)
    images = Chat.images_dir(project, chat.id)
    File.mkdir_p!(images)
    File.write!(Path.join(images, "k2j4.png"), "png bytes")
    %{project: project, chat: chat}
  end

  test "a chat's image is for those who can open its project", %{
    conn: conn,
    project: project,
    chat: chat
  } do
    path = ~p"/projects/#{project.id}/c/#{chat.id}/images/k2j4.png"

    conn = get(conn, path)
    assert response(conn, 200) == "png bytes"
    assert response_content_type(conn, :png)

    stranger = log_in_user(build_conn(), user_fixture())
    assert response(get(stranger, path), 404)
  end

  test "only images by their own names, of the chat's own project", %{
    conn: conn,
    project: project,
    chat: chat
  } do
    assert response(get(conn, ~p"/projects/#{project.id}/c/#{chat.id}/images/nope.png"), 404)
    assert response(get(conn, "/projects/#{project.id}/c/#{chat.id}/images/..%2Fx.png"), 404)
    assert response(get(conn, ~p"/projects/#{project.id + 1}/c/#{chat.id}/images/k2j4.png"), 404)
  end
end
