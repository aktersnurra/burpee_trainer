defmodule BurpeeTrainerWeb.StaticFilesTest do
  use BurpeeTrainerWeb.ConnCase, async: false

  # In production `mix phx.digest` fingerprints every static file, and the layout links
  # the fingerprinted names, `/favicon-<digest>.ico`; a browser without a cached copy
  # requests exactly those.
  for {file, digested} <- [
        {"favicon.ico", "favicon-0123456789abcdef0123456789abcdef.ico"},
        {"manifest.webmanifest", "manifest-0123456789abcdef0123456789abcdef.webmanifest"}
      ] do
    test "the fingerprinted #{file} is served", %{conn: conn} do
      static = Application.app_dir(:burpee_trainer, "priv/static")
      original = File.read!(Path.join(static, unquote(file)))
      File.write!(Path.join(static, unquote(digested)), original)
      on_exit(fn -> File.rm(Path.join(static, unquote(digested))) end)

      conn = get(conn, "/" <> unquote(digested))

      assert conn.status == 200
      assert conn.resp_body == original
    end
  end
end
