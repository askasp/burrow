defmodule Peon.Template do
  @moduledoc """
  Instantiates the template app for a new project: copies its files, renaming
  `PeonTemplate` / `peon_template` to the project's module and OTP app name in
  paths and contents.
  """

  @module "PeonTemplate"
  @otp_app "peon_template"

  @doc "Returns `{tree, blobs}` for `PeonCore.Tree`, ready to import."
  def instantiate(template_dir, otp_app) do
    module = Macro.camelize(otp_app)
    {tree, blobs} = PeonCore.Tree.from_dir(template_dir, PeonCore.Ignore.matcher(template_dir))

    Enum.reduce(tree, {%{}, %{}}, fn {path, hash}, {tree, new_blobs} ->
      content = rename(Map.fetch!(blobs, hash), module, otp_app)
      new_hash = PeonCore.Blob.hash(content)

      {Map.put(tree, rename(path, module, otp_app), new_hash),
       Map.put(new_blobs, new_hash, content)}
    end)
  end

  @doc "Turns a project slug into a valid OTP app name."
  def otp_app(slug) do
    name = slug |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")
    if name =~ ~r/^[a-z]/, do: name, else: "app_" <> name
  end

  defp rename(text, module, otp_app) do
    text |> String.replace(@module, module) |> String.replace(@otp_app, otp_app)
  end
end
