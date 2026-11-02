defmodule BurpeeTrainerWeb.StudioHelpers do
  @moduledoc "Drives Home's buttons and New's form in a LiveView test, as a person would."
  import Phoenix.LiveViewTest

  @doc "Edit, one tap from Home."
  def open_edit(view), do: view |> element("#home-corner-edit") |> render_click()

  @doc "New, one tap from Home."
  def open_new(view), do: view |> element("#home-corner-new") |> render_click()

  @doc "Swipes right: the swap drawer, which opens from anywhere on Home."
  def open_swap(view), do: render_click(view, "open_chooser", %{})

  @doc """
  Opens New and fills its form: type, style, minutes and reps typed, `max_set` (unbroken only)
  typed, and `pace_ups` raising the pace from where it is by half a second each.
  """
  def walk(view, opts \\ []) do
    open_new(view)
    fill(view, "burpee_type", Keyword.get(opts, :type, "six_count"))
    style = Keyword.get(opts, :style, "unbroken")
    fill(view, "pacing_style", style)
    fill(view, "duration", Keyword.get(opts, :minutes, 20))
    fill(view, "reps", Keyword.get(opts, :reps, 50))

    max_set = Keyword.get(opts, :max_set)
    if style == "unbroken" and max_set, do: fill(view, "sets", max_set)

    for _ <- List.duplicate(0, Keyword.get(opts, :pace_ups, 0)),
        do: view |> element("#studio-pace-up") |> render_click()
  end

  @doc "Sets the form's `field` to `value`, as typing or choosing it does."
  def fill(view, field, value) do
    view
    |> form("#studio-new-form", new: %{field => to_string(value)})
    |> render_change(%{"_target" => ["new", field]})
  end

  @doc "The value the form shows for `field`."
  def shown(view, field) do
    view
    |> element("#studio-#{field}")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  @doc "Sends the form as it is."
  def create(view), do: view |> form("#studio-new-form") |> render_submit()

  @doc "Sends the form with `text` as its note."
  def request(view, text),
    do: view |> form("#studio-new-form", new: %{note: text}) |> render_submit()

  @doc "Presses a button until it is disabled."
  def press_while_possible(view, selector) do
    if has_element?(view, selector <> ":not([disabled])") do
      view |> element(selector) |> render_click()
      press_while_possible(view, selector)
    end
  end
end
