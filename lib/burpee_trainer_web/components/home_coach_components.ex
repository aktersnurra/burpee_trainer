defmodule BurpeeTrainerWeb.HomeCoachComponents do
  @moduledoc "Small recommendation-first presentation primitives for Home."

  use BurpeeTrainerWeb, :html

  attr(:eyebrow, :string, required: true)
  attr(:title, :string, required: true)
  attr(:detail, :string, required: true)

  def recommendation_heading(assigns) do
    ~H"""
    <div class="space-y-3">
      <p class="text-sm font-semibold uppercase tracking-[0.18em] text-slate-500">
        {@eyebrow}
      </p>
      <h1 class="text-3xl font-semibold tracking-tight text-slate-950">
        {@title}
      </h1>
      <p class="text-base text-slate-600">{@detail}</p>
    </div>
    """
  end
end
