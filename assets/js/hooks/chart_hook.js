// Renders a Chart.js time-series line chart from data attached to the
// element via `data-chart`. Re-renders when the data changes.
import Chart from "chart.js/auto"
import "chartjs-adapter-date-fns"

const ChartHook = {
  mounted() {
    this.chart = this.buildChart()
  },

  updated() {
    if (!this.chart) return
    const data = this.readData()
    this.chart.data = data
    this.chart.update()
  },

  destroyed() {
    if (this.chart) this.chart.destroy()
  },

  readData() {
    const raw = this.el.dataset.chart
    if (!raw) return {datasets: []}
    try { return JSON.parse(raw) }
    catch { return {datasets: []} }
  },

  buildChart() {
    const ctx = this.el.getContext("2d")
    return new Chart(ctx, {
      type: "line",
      data: this.readData(),
      options: {
        responsive: true,
        maintainAspectRatio: false,
        parsing: {xAxisKey: "x", yAxisKey: "y"},
        scales: {
          x: {type: "time", time: {unit: "day", tooltipFormat: "PP"}},
          y: {beginAtZero: true, title: {display: true, text: "Burpees"}}
        },
        plugins: {
          legend: {position: "top"},
          tooltip: {mode: "nearest", intersect: false}
        }
      }
    })
  }
}

export default ChartHook
