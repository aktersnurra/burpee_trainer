defmodule BurpeeTrainer.Evals.RecorderTest do
  use ExUnit.Case, async: true
  alias BurpeeTrainer.Evals.Recorder

  test "response-only recording preserves order; explicit synthetic provenance" do
    counter = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"choices" => [], "usage" => %{}})
    end)

    req = Recorder.attach(Req.new(plug: {Req.Test, __MODULE__}), counter)

    Req.post!(req,
      url: "https://provider.test/v1",
      headers: [{"authorization", "Bearer never-record-this"}]
    )

    assert Recorder.responses(counter) == [%{"choices" => [], "usage" => %{}}]
    root = Path.join(System.tmp_dir!(), "eval-record-#{Ecto.UUID.generate()}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    Recorder.write!(root, "synthetic", Recorder.responses(counter), %{
      capture_kind: "req_test",
      provider_model: "m"
    })

    assert Jason.decode!(File.read!(Path.join(root, "synthetic.json"))) ==
             Recorder.responses(counter)

    assert Jason.decode!(File.read!(Path.join(root, "synthetic.provenance.json")))["capture_kind"] ==
             "req_test"

    refute File.read!(Path.join(root, "synthetic.json")) =~ "never-record-this"
  end
end
