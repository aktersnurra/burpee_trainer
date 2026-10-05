defmodule BurpeeTrainer.Accounts.Scope do
  @moduledoc "The caller's authorization scope; every user-facing query filters by `user.id`."

  alias BurpeeTrainer.Accounts.User

  @enforce_keys [:user]
  defstruct [:user]

  @type t :: %__MODULE__{user: User.t()}

  @spec for_user(User.t() | nil) :: t() | nil
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
