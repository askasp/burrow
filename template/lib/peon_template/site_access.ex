defmodule PeonTemplate.SiteAccess do
  @moduledoc """
  Who can see the app. Change `mode/0` to switch; nothing else has to change.

    * `:login` - people log in with email and password. The app's pages (the
      router's `:app` scope) need a logged-in user.
    * `:shared_password` - one password for everyone, no accounts. The owner
      sets it in Peon as the secret `SITE_PASSWORD`; until then nobody gets in.
    * `:public` - anyone can see every page.
  """

  @type mode :: :login | :shared_password | :public

  @spec mode() :: mode()
  def mode, do: :login

  @doc "Whether people have accounts, so the header offers log in and register."
  def accounts?, do: accounts?(mode())

  # By pattern, not `==`: the compiler knows what `mode/0` returns and warns
  # about comparisons that are always true or always false.
  @doc false
  def accounts?(:login), do: true
  def accounts?(_mode), do: false
end
