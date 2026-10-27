defmodule BurrowWeb.LoginLive.Index do
  @moduledoc """
  Logins, for admins: sign-ups are closed, so an admin makes an account for
  someone here and sends them what the page shows (where to log in, the
  email, a new password). Burrow mails nothing, so the admin passes it on.
  Admins also delete others' logins here (`Burrow.Accounts.delete_user/2`).
  """

  use BurrowWeb, :live_view

  alias Burrow.Accounts
  alias BurrowWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope.user.admin do
      {:ok,
       socket
       |> assign(page_title: "Logins", form: email_form(), made: nil)
       |> assign(users: Accounts.list_users())}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only admins make logins.")
       |> push_navigate(to: ~p"/projects")}
    end
  end

  defp email_form(email \\ ""), do: to_form(%{"email" => email}, as: "login")

  # The server keeps what's typed, so the box empties after a login is made.
  @impl true
  def handle_event("typed", %{"login" => %{"email" => email}}, socket),
    do: {:noreply, assign(socket, form: email_form(email))}

  def handle_event("create", %{"login" => %{"email" => email}}, socket) do
    case Accounts.create_login(socket.assigns.current_scope.user, email) do
      {:ok, user, password} ->
        {:noreply,
         socket
         |> assign(form: email_form(), made: {user, password})
         |> assign(users: Accounts.list_users())}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: "login"), made: nil)}

      {:error, :not_admin} ->
        {:noreply, put_flash(socket, :error, "Only admins make logins.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.delete_user(socket.assigns.current_scope.user, user) do
      {:ok, {user, tokens}} ->
        UserAuth.disconnect_sessions(tokens)

        {:noreply,
         socket
         |> put_flash(:info, "Deleted #{user.email}.")
         |> assign(users: Accounts.list_users())}

      {:error, :self} ->
        {:noreply, put_flash(socket, :error, "You can't delete your own login.")}

      {:error, :not_admin} ->
        {:noreply, put_flash(socket, :error, "Only admins delete logins.")}
    end
  end

  defp message({user, password}) do
    """
    You have a Peon login.
    Log in at #{url(~p"/users/log-in")}
    Email: #{user.email}
    Password: #{password}
    Change the password under your email (top right) once you're in, and add your own AI login on the AI login page.
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:logins}>
      <div class="flex items-start justify-between gap-5 flex-wrap">
        <div class="flex flex-col gap-1">
          <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">Logins</h1>
          <p class="m-0 text-[15px] text-[var(--text-2)]">
            Sign-ups are closed. Make a login for someone, then send them what shows up.
          </p>
        </div>
        <.form
          for={@form}
          id="login-form"
          phx-change="typed"
          phx-submit="create"
          class="flex gap-2 items-start flex-[0_1_420px]"
        >
          <div class="flex-1 min-w-0">
            <.input
              field={@form[:email]}
              type="email"
              label="Their email"
              placeholder="friend@example.com"
              autocomplete="off"
              required
            />
          </div>
          <.button variant="primary" class="btn btn-primary mt-[27px]" phx-disable-with="Making…">
            Make login
          </.button>
        </.form>
      </div>

      <section :if={@made} id="new-login" class="flex flex-col gap-2 max-w-[640px]">
        <div class="sec-h">
          <span class="eyebrow">Send this to {elem(@made, 0).email}</span>
        </div>
        <textarea
          id="new-login-message"
          readonly
          rows="6"
          class="w-full mono text-[13px] p-3 rounded-lg border border-[var(--border)] bg-transparent"
        >{message(@made)}</textarea>
        <span class="text-[13px] text-[var(--text-3)]">
          The password shows only now. Burrow keeps just its hash.
        </span>
      </section>

      <div>
        <div class="sec-h"><span class="eyebrow">Everyone with a login</span></div>
        <ul id="users" class="rows">
          <li :for={u <- @users} id={"user-#{u.id}"}>
            <span class="flex-1 min-w-0 truncate">{u.email}</span>
            <span :if={u.admin} class="tag">admin</span>
            <span class="mono text-[12px] text-[var(--text-3)]">
              since {Calendar.strftime(u.inserted_at, "%Y-%m-%d")}
            </span>
            <button
              :if={u.id != @current_scope.user.id}
              id={"delete-user-#{u.id}"}
              type="button"
              class="icon-btn sm"
              aria-label={"Delete #{u.email}"}
              phx-click="delete"
              phx-value-id={u.id}
              data-confirm={"Delete #{u.email} for good? Their projects shared with a team go to a teammate; their other projects and chats are deleted."}
            >
              <.icon name="hero-trash" class="size-4" />
            </button>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
