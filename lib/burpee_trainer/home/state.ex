defmodule BurpeeTrainer.Home.State do
  @moduledoc "Pure: facts to the one thing Home shows."

  alias BurpeeTrainer.Home.Facts

  @type t ::
          {:resume, map()}
          | {:start, map()}
          | :choose
          | {:done_today, map()}
          | {:week_complete, map()}

  @spec derive(Facts.t()) :: t()
  def derive(%Facts{started_session: %{} = session}), do: {:resume, session}

  def derive(%Facts{slot: %{home_state: :done_today}, results: results}),
    do: {:done_today, results}

  def derive(%Facts{slot: %{home_state: :week_complete}, results: results}),
    do: {:week_complete, results}

  def derive(%Facts{selection: %{} = selection}), do: {:start, selection}
  def derive(%Facts{}), do: :choose

  @spec primary_action(t()) :: :resume | :start | :choose | :insights
  def primary_action({:resume, _}), do: :resume
  def primary_action({:start, _}), do: :start
  def primary_action(:choose), do: :choose
  def primary_action({state, _}) when state in [:done_today, :week_complete], do: :insights
end
