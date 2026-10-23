defmodule BurrowWeb.UserLive.Login do
  use BurrowWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} current_scope={@current_scope}>
      <div class="flex flex-col gap-2">
        <h1 class="m-0 text-[32px] leading-10 font-semibold tracking-[-0.02em]">Log in</h1>
        <p :if={@current_scope} class="m-0 text-[15px] text-[var(--text-2)]">
          Log in again to change your account settings.
        </p>
      </div>

      <.form
        :let={f}
        for={@form}
        id="login_form_password"
        action={~p"/users/log-in"}
        phx-submit="submit_password"
        phx-trigger-action={@trigger_submit}
        class="flex flex-col"
      >
        <.input
          readonly={!!@current_scope}
          field={f[:email]}
          type="email"
          label="Email"
          autocomplete="username"
          spellcheck="false"
          placeholder="you@example.com"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:password]}
          type="password"
          label="Password"
          autocomplete="current-password"
          spellcheck="false"
          reveal
        />
        <.button
          variant="primary"
          class="btn btn-primary btn-lg w-full mt-2"
          name={@form[:remember_me].name}
          value="true"
        >
          Log in
        </.button>
        <button type="submit" name="magic" value="true" class="btn btn-ghost w-full mt-2">
          Email me a login link
        </button>
      </.form>

      <div
        :if={!@current_scope and Burrow.Accounts.sign_ups?()}
        class="pt-5 border-t border-[var(--border)] text-sm leading-5 text-[var(--text-2)]"
      >
        New to Peon? <.link navigate={~p"/users/register"}>Create an account</.link>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", %{"magic" => "true", "user" => %{"email" => email}}, socket) do
    if user = Burrow.Accounts.get_user_by_email(email) do
      Burrow.Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
    end

    info = "If your email is in our system, you will receive a login link shortly."
    {:noreply, socket |> put_flash(:info, info) |> push_navigate(to: ~p"/users/log-in")}
  end

  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
