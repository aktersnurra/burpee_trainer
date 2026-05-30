export function createPoseTracker(hook) {
  return {
    async mounted() {
      hook.pushEvent("tracker_ready", {})
    },

    destroyed() {}
  }
}
