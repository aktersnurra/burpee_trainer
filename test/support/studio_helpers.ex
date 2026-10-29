defmodule BurpeeTrainerWeb.StudioHelpers do
  @moduledoc "Drives New's questions in a LiveView test, as a person would: by taps and steps."
  import Phoenix.LiveViewTest

  @doc "Opens New from Home."
  def open_new(view) do
    view |> element("#home-summary") |> render_click()
    view |> element("#home-new-workout") |> render_click()
  end

  @doc """
  Answers every question and stops at what was chosen. Reps and minutes are reached by steps;
  `pace_ups` raises the pace from its default by half a second each; `max_set` limits a set
  (unbroken only).
  """
  def walk(view, opts \\ []) do
    open_new(view)
    style = Keyword.get(opts, :style, "unbroken")

    view
    |> element("#home-pill-burpee_type-#{Keyword.get(opts, :type, "six_count")}")
    |> render_click()

    view |> element("#home-pill-pacing_style-#{style}") |> render_click()

    step_to(view, "duration", Keyword.get(opts, :minutes, 20))
    view |> element("#studio-next") |> render_click()
    step_to(view, "reps", Keyword.get(opts, :reps, 50))
    view |> element("#studio-next") |> render_click()

    if style == "unbroken" do
      if max = Keyword.get(opts, :max_set), do: step_set_size_to(view, max)
      view |> element("#studio-next") |> render_click()
    end

    for _ <- List.duplicate(0, Keyword.get(opts, :pace_ups, 0)),
        do: view |> element("#studio-pace-up") |> render_click()

    view |> element("#studio-next") |> render_click()
  end

  @doc "Sends what was chosen as it is."
  def create(view), do: view |> element("#studio-create") |> render_click()

  @doc "Opens the chat on what was chosen and sends it with `text` as the request."
  def request(view, text) do
    view |> element("#studio-add-request") |> render_click()

    view
    |> Phoenix.LiveViewTest.form("#home-edit-form", home_adjustment: %{instruction: text})
    |> render_submit()
  end

  defp step_set_size_to(view, max) do
    shown = view |> element("#studio-sets-value") |> render() |> text()

    cond do
      shown == to_string(max) ->
        :ok

      has_element?(view, "#studio-sets-down:not([disabled])") ->
        view |> element("#studio-sets-down") |> render_click()
        step_set_size_to(view, max)
    end
  end

  @doc "Steps `field` (duration, reps) to `target`."
  def step_to(view, field, target) do
    current =
      view |> element("#studio-#{field}-value") |> render() |> text() |> String.to_integer()

    cond do
      current == target ->
        :ok

      current < target ->
        view |> element("#studio-#{field}-up") |> render_click()
        step_to(view, field, target)

      true ->
        view |> element("#studio-#{field}-down") |> render_click()
        step_to(view, field, target)
    end
  end

  @doc "Presses a button until it is disabled."
  def press_while_possible(view, selector) do
    if has_element?(view, selector <> ":not([disabled])") do
      view |> element(selector) |> render_click()
      press_while_possible(view, selector)
    end
  end

  defp text(html), do: html |> LazyHTML.from_fragment() |> LazyHTML.text() |> String.trim()
end
