defmodule BurpeeTrainerWeb.StartChoices do
  @moduledoc """
  How a workout starts on this device (camera, warmup), as the device remembers it: the two
  cookies Home's start toggles write (`assets/js/hooks/start_choices.mjs`). Home renders the
  toggles from it so they are right from the first paint.

  A page load reads the cookies into the LiveView session (`session/1`, the `:authed` live
  session's extra session); a join reads them from the connect params the browser sends at
  every join, since a Home reached by live navigation would otherwise see the session from
  the page load.
  """

  @defaults %{"camera" => false, "warmup" => true}

  @type t :: %{String.t() => boolean()}

  @doc "The live session's extra session: the choices in this request's cookies."
  @spec session(Plug.Conn.t()) :: %{String.t() => t()}
  def session(conn) do
    choices =
      Map.new(@defaults, fn {choice, default} ->
        value =
          case conn.cookies["burpee_start_" <> choice] do
            "1" -> true
            "0" -> false
            _ -> default
          end

        {choice, value}
      end)

    %{"start_choices" => choices}
  end

  @doc "The choices a join sent in its connect params; the defaults if it sent none."
  @spec from_connect_params(map() | nil) :: t()
  def from_connect_params(%{"start_choices" => %{"camera" => camera, "warmup" => warmup}})
      when is_boolean(camera) and is_boolean(warmup),
      do: %{"camera" => camera, "warmup" => warmup}

  def from_connect_params(_), do: @defaults

  @doc "The choices with one changed by its toggle; anything else leaves them as they are."
  @spec put(t(), term(), term()) :: t()
  def put(choices, choice, pressed)
      when is_map_key(@defaults, choice) and is_boolean(pressed),
      do: Map.put(choices, choice, pressed)

  def put(choices, _choice, _pressed), do: choices
end
