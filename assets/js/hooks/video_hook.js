const VideoHook = {
  mounted() {
    this.el.addEventListener("ended", () => this.pushEvent("video_ended", {}));
  },
};

export default VideoHook;
