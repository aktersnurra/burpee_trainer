defmodule BurpeeTrainerWeb.ScimAuth do
  @moduledoc """
  Admits Pocket ID's SCIM requests by the shared Bearer token (`SCIM_TOKEN`). Without a
  configured token `/scim/v2` does not exist (404). The token is never logged.
  """

  import Plug.Conn

  alias BurpeeTrainer.Scim

  def init(opts), do: opts

  def call(conn, _opts) do
    case {Scim.token(), get_req_header(conn, "authorization")} do
      {:off, _header} ->
        conn |> send_resp(404, "") |> halt()

      {{:token, token}, ["Bearer " <> sent]} ->
        if Plug.Crypto.secure_compare(String.trim(sent), token),
          do: conn,
          else: unauthorized(conn)

      {{:token, _token}, _header} ->
        unauthorized(conn)
    end
  end

  defp unauthorized(conn),
    do: conn |> BurpeeTrainerWeb.ScimJSON.error(401, "Invalid SCIM token") |> halt()
end
