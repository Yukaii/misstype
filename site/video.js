// Player chrome for the demo video, drawn in the page's style instead of the
// browser's. The <video> keeps its native `controls` in the HTML so it still
// plays without JS; this swaps them for a big play button over the poster and
// a strip under the picture (play, time, scrubber, mute, fullscreen). The
// strip stays outside the frame so it never covers the burned-in captions.
(function () {
  var zh = document.documentElement.lang.indexOf("zh") === 0;
  var T = zh
    ? { play: "播放", pause: "暫停", mute: "靜音", unmute: "取消靜音", full: "全螢幕", exit: "離開全螢幕", seek: "播放進度" }
    : { play: "Play", pause: "Pause", mute: "Mute", unmute: "Unmute", full: "Full screen", exit: "Exit full screen", seek: "Seek" };

  var ICON = {
    play: '<path d="M5 3.5v9l7.5-4.5z"/>',
    pause: '<path d="M4.5 3.5h2.5v9H4.5zM9 3.5h2.5v9H9z"/>',
    sound: '<path d="M2.5 6h2.5l3.5-3v10L5 10H2.5z"/><path class="o" d="M11 5.5a3.5 3.5 0 0 1 0 5M12.8 3.8a6 6 0 0 1 0 8.4"/>',
    muted: '<path d="M2.5 6h2.5l3.5-3v10L5 10H2.5z"/><path class="o" d="M10.5 6l4 4M14.5 6l-4 4"/>',
    full: '<path class="o" d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/>',
    exit: '<path class="o" d="M6 2.5V6H2.5M13.5 6H10V2.5M10 13.5V10h3.5M2.5 10H6v3.5"/>',
  };
  var svg = function (name) {
    return '<svg viewBox="0 0 16 16" aria-hidden="true">' + ICON[name] + "</svg>";
  };

  document.querySelectorAll("video.video").forEach(function (video) {
    var player = document.createElement("div");
    player.className = "player";
    player.dataset.state = "idle";
    var stage = document.createElement("div");
    stage.className = "player-stage";
    video.parentNode.insertBefore(player, video);
    stage.appendChild(video);
    player.appendChild(stage);
    video.controls = false;

    var big = button("player-big", T.play, svg("play"));
    var bar = document.createElement("div");
    bar.className = "player-bar";
    var toggle = button("player-btn", T.play, svg("play"));
    var time = document.createElement("span");
    time.className = "player-time";
    var seek = document.createElement("input");
    seek.type = "range";
    seek.className = "player-seek";
    seek.min = 0;
    seek.max = 1000;
    seek.step = 1;
    seek.value = 0;
    seek.setAttribute("aria-label", T.seek);
    var mute = button("player-btn", T.mute, svg("sound"));
    var full = button("player-btn", T.full, svg("full"));
    bar.append(toggle, time, seek, mute, full);
    stage.appendChild(big);
    player.appendChild(bar);

    function button(cls, label, html) {
      var b = document.createElement("button");
      b.type = "button";
      b.className = cls;
      b.setAttribute("aria-label", label);
      b.innerHTML = html;
      return b;
    }
    function relabel(b, label, icon) {
      b.setAttribute("aria-label", label);
      b.title = label;
      b.innerHTML = svg(icon);
    }
    function clock(s) {
      s = Math.max(0, Math.floor(s || 0));
      return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }

    var scrubbing = false;
    function render() {
      var d = video.duration || 0;
      var t = video.currentTime || 0;
      if (!scrubbing) seek.value = d ? Math.round((t / d) * 1000) : 0;
      seek.style.setProperty("--p", (seek.value / 10) + "%");
      seek.setAttribute("aria-valuetext", clock(t) + " / " + clock(d));
      time.textContent = clock(t) + " / " + clock(d);
    }
    function sync() {
      var paused = video.paused || video.ended;
      if (!paused) player.dataset.state = "started";
      relabel(toggle, paused ? T.play : T.pause, paused ? "play" : "pause");
      relabel(mute, video.muted ? T.unmute : T.mute, video.muted ? "muted" : "sound");
    }
    function play() {
      if (video.paused || video.ended) video.play();
      else video.pause();
    }


    big.addEventListener("click", play);
    toggle.addEventListener("click", play);
    video.addEventListener("click", play);
    mute.addEventListener("click", function () { video.muted = !video.muted; });
    full.addEventListener("click", function () {
      if (document.fullscreenElement) document.exitFullscreen();
      else if (player.requestFullscreen) player.requestFullscreen();
      else if (video.webkitEnterFullscreen) video.webkitEnterFullscreen(); // iOS
    });
    document.addEventListener("fullscreenchange", function () {
      var on = document.fullscreenElement === player;
      relabel(full, on ? T.exit : T.full, on ? "exit" : "full");
    });

    seek.addEventListener("input", function () {
      scrubbing = true;
      if (video.duration) video.currentTime = (seek.value / 1000) * video.duration;
      render();
    });
    seek.addEventListener("change", function () { scrubbing = false; });

    player.addEventListener("keydown", function (e) {
      if (e.target === seek && e.key !== " ") return;
      if (e.key === " " || e.key === "k") {
        if (e.target.tagName === "BUTTON" && e.key === " ") return;
        e.preventDefault();
        play();
      } else if (e.key === "m") {
        video.muted = !video.muted;
      } else if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
        e.preventDefault();
        video.currentTime += e.key === "ArrowLeft" ? -5 : 5;
      }
    });

    ["play", "pause", "ended", "volumechange"].forEach(function (ev) { video.addEventListener(ev, sync); });
    ["timeupdate", "loadedmetadata", "durationchange", "seeked"].forEach(function (ev) { video.addEventListener(ev, render); });
    // preload="none" leaves the duration unknown until play; fetch just the
    // header so the bar can show the length up front.
    video.preload = "metadata";
    sync();
    render();
  });
})();
