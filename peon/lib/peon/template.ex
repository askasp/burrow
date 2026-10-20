defmodule Peon.Template do
  @moduledoc """
  Instantiates the template app for a new project: copies its files, renaming
  `PeonTemplate` / `peon_template` to the project's module and OTP app name in
  paths and contents.

  The project picks its login (`auth`):

    * `"accounts"` - the template as it is: phx.gen.auth's email and password
      accounts, `SiteAccess` mode `:login`.
    * `"basic"` - no accounts; the browser asks for one username and password
      (`SiteAccess` mode `:basic_auth`, the secrets `BASIC_AUTH_USERNAME` and
      `BASIC_AUTH_PASSWORD`).
    * `"open"` - no accounts and no login (`SiteAccess` mode `:public`).

  Without accounts, the accounts code is left out, following markers in the
  template's comments (`#`, `<%!--` or `<!--`, whole line):

    * `peon:accounts-only` - the whole file is left out.
    * `peon:if-accounts` ... `peon:end` - lines only apps with accounts get.
    * `peon:unless-accounts` ... `peon:end` - lines only apps without accounts
      get. Only for text and comments: the template itself runs with accounts.

  The marker lines themselves never reach the app.
  """

  @module "PeonTemplate"
  @otp_app "peon_template"
  @auths ~w(accounts basic open)
  @site_access "lib/peon_template/site_access.ex"
  @default_mode "def mode, do: :login"

  @marker ~r/^\s*(?:#|<%!--|<!--)\s*peon:(accounts-only|if-accounts|unless-accounts|end)\b/

  @doc "The logins a new project can start with."
  def auths, do: @auths

  @doc "Returns `{tree, blobs}` for `PeonCore.Tree`, ready to import."
  def instantiate(template_dir, otp_app, auth \\ "accounts") when auth in @auths do
    module = Macro.camelize(otp_app)
    {tree, blobs} = PeonCore.Tree.from_dir(template_dir, PeonCore.Ignore.matcher(template_dir))
    accounts? = auth == "accounts"

    Enum.reduce(tree, {%{}, %{}}, fn {path, hash}, {tree, new_blobs} ->
      case variant(path, Map.fetch!(blobs, hash), accounts?) do
        :skip ->
          {tree, new_blobs}

        {:ok, content} ->
          content = content |> set_mode(path, auth) |> rename(module, otp_app)
          new_hash = PeonCore.Blob.hash(content)

          {Map.put(tree, rename(path, module, otp_app), new_hash),
           Map.put(new_blobs, new_hash, content)}
      end
    end)
  end

  @doc "Turns a project slug into a valid OTP app name."
  def otp_app(slug) do
    name = slug |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    if name =~ ~r/^[a-z]/, do: name, else: "app_" <> name
  end

  @doc false
  # A file as an app with or without accounts gets it: `{:ok, content}` or `:skip`.
  def variant(path, content, accounts?) do
    if String.contains?(content, "peon:") and String.valid?(content),
      do: apply_markers(path, content, accounts?),
      else: {:ok, content}
  end

  defp apply_markers(path, content, accounts?) do
    {lines, block, skip?} =
      content
      |> String.split("\n")
      |> Enum.reduce({[], nil, false}, fn line, {lines, block, skip?} ->
        case {Regex.run(@marker, line, capture: :all_but_first), block} do
          {nil, nil} -> {[line | lines], nil, skip?}
          {nil, keep?} -> {if(keep?, do: [line | lines], else: lines), block, skip?}
          {["accounts-only"], nil} -> {lines, nil, skip? or not accounts?}
          {["if-accounts"], nil} -> {lines, accounts?, skip?}
          {["unless-accounts"], nil} -> {lines, not accounts?, skip?}
          {["end"], keep?} when keep? != nil -> {lines, nil, skip?}
          {[marker], _} -> raise ArgumentError, "#{path}: unexpected peon:#{marker}"
        end
      end)

    cond do
      block != nil -> raise ArgumentError, "#{path}: a peon:if block has no peon:end"
      skip? -> :skip
      true -> {:ok, lines |> Enum.reverse() |> Enum.join("\n")}
    end
  end

  # The login the app starts with is the one line in SiteAccess.
  defp set_mode(content, @site_access, "accounts"), do: content

  defp set_mode(content, @site_access, auth) do
    mode = if auth == "basic", do: ":basic_auth", else: ":public"

    if String.contains?(content, @default_mode),
      do: String.replace(content, @default_mode, "def mode, do: " <> mode),
      else: raise(ArgumentError, "#{@site_access} has no `#{@default_mode}` line")
  end

  defp set_mode(content, _path, _auth), do: content

  defp rename(text, module, otp_app) do
    text |> String.replace(@module, module) |> String.replace(@otp_app, otp_app)
  end
end
