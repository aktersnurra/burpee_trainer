// Renders a Chart.js time-series line chart from data attached to the
// element via `data-chart`. Re-renders when the data changes.
import Chart from "chart.js/auto";
import "chartjs-adapter-date-fns";

const ChartHook = {
  mounted() {
    this.chart = this.buildChart();
  },

  updated() {
    if (!this.chart) return;
    this.chart.data = this.readData();
    this.chart.resize();
    this.chart.update("none");
  },

  destroyed() {
    if (this.chart) this.chart.destroy();
  },

  readData() {
    const raw = this.el.dataset.chart;
    if (!raw) return { datasets: [] };
    try {
      return JSON.parse(raw);
    } catch {
      return { datasets: [] };
    }
  },

  buildChart() {
    const ctx = this.el.getContext("2d");
    return new Chart(ctx, {
      type: "line",
      data: this.readData(),
      options: {
        responsive: true,
        maintainAspectRatio: false,
        parsing: { xAxisKey: "x", yAxisKey: "y" },
        animation: false,
        scales: {
          x: {
            type: "time",
            time: { unit: "day", tooltipFormat: "PP" },
            grid: { color: "rgba(255,255,255,0.04)" },
            ticks: { color: "#596170", font: { size: 11 } },
          },
          y: {
            beginAtZero: true,
            grid: { color: "rgba(255,255,255,0.04)" },
            ticks: { color: "#596170", font: { size: 11 } },
          },
        },
        plugins: {
          legend: { display: false },
          tooltip: {
            mode: "nearest",
            intersect: false,
            backgroundColor: "#181C26",
            borderColor: "#1E2535",
            borderWidth: 1,
            titleColor: "#E2E8F4",
            bodyColor: "#9BA8BF",
            padding: 10,
            cornerRadius: 6,
          },
        },
      },
    });
  },
};

export default ChartHook;
