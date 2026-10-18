defmodule BurpeeTrainer.ReqStub do
  @moduledoc """
  A Req adapter module that runs a test's function, since Req deprecates function adapters.

  `default/1` stubs every request (like `Req.default_options/1`, it is global, so only for
  `async: false` tests); `attach/2` stubs one request.
  """

  def default(fun) when is_function(fun, 1) do
    Application.put_env(:burpee_trainer, __MODULE__, fun)
    Req.default_options(adapter: __MODULE__)
  end

  def attach(%Req.Request{} = request, fun) when is_function(fun, 1) do
    %{Req.Request.put_private(request, __MODULE__, fun) | adapter: __MODULE__}
  end

  def run(request) do
    fun =
      Req.Request.get_private(request, __MODULE__) ||
        Application.fetch_env!(:burpee_trainer, __MODULE__)

    fun.(request)
  end
end
