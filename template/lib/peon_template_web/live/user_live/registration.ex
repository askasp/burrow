# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplateWeb.UserLive.Registration do
  use PeonTemplateWeb, :live_view

  alias PeonTemplate.Accounts
  alias PeonTemplate.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              <span :if={@first?} class="block">
                You are the first: this account is the admin, who adds the others.
              </span>
              Already registered?
              <.link navigate={~p"/users/log-in"} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form
          for={@form}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={@trigger_submit}
          action={~p"/users/log-in?_action=registered"}
          method="post"
        >
          <.input
            field={@form[:email]}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{assigns: %{current_scope: %{user: user}}} = socket)
      when not is_nil(user) do
    {:ok, redirect(socket, to: PeonTemplateWeb.UserAuth.signed_in_path(socket))}
  end

  def mount(_params, _session, socket) do
    if Accounts.registration_open?() do
      changeset = Accounts.change_user_registration(%User{})

      {:ok,
       socket
       |> assign(trigger_submit: false, first?: Accounts.no_users?())
       |> assign_form(changeset)}
    else
      {:ok, closed(socket)}
    end
  end

  @impl true
  def handle_event("save", %{"user" => user_params}, socket) do
    if Accounts.registration_open?(),
      do: register(socket, user_params),
      else: {:noreply, closed(socket)}
  end

  def handle_event("validate", %{"user" => user_params}, socket) do
    changeset = Accounts.change_user_registration(%User{}, user_params)
    {:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}
  end

  # Sign-ups are closed (`PeonTemplate.SiteAccess.signups?/0`) and the admin exists.
  defp closed(socket) do
    socket
    |> put_flash(:error, "Sign-ups are closed. Ask an admin for an account.")
    |> redirect(to: ~p"/users/log-in")
  end

  defp register(socket, user_params) do
    case Accounts.register_user_with_password(user_params) do
      {:ok, user} ->
        changeset = Accounts.change_user_registration(user, user_params)
        {:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
