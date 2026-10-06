// The fake text field at the top plays the examples listed on the page: each
// <li> carries the keys that were typed (data-keys) and the text Misstype
// produced (.got). Without JS, or with reduced motion, the field keeps its
// static first example.
//
// Clicking the field swaps it for the real decoder (WebAssembly, downloaded
// on demand). If that is unavailable or fails, the animation just carries on.
(function () {
  var demo = document.querySelector(".demo");
  var field = document.querySelector(".field");
  var caption = document.querySelector(".demo .keys");
  var hint = document.querySelector(".demo .try");
  var items = document.querySelectorAll(".examples li[data-keys]");
  if (!demo || !field || !caption) return;

  var stopped = false;
  var reduced = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  if (items.length) animate();
  if (hint && typeof WebAssembly === "object") {
    hint.hidden = false;
    var requested = false;
    var playground = null;
    var host = document.createElement("div");
    host.hidden = true;
    demo.insertBefore(host, field);

    function reveal() {
      if (!requested || !playground?.ready) return;
      stopped = true;
      field.hidden = caption.hidden = hint.hidden = true;
      host.hidden = false;
      playground.boxEl.focus();
    }

    // Warm the dynamically imported decoder after the page paints. The live
    // editor stays hidden and never takes focus until the visitor activates it.
    var loadingPromise;
    function preload() {
      if (!loadingPromise) {
        loadingPromise = load().catch(function (err) {
          console.error(err);
          host.remove();
          field.removeAttribute("aria-busy");
          hint.textContent = hint.dataset.failed;
        });
      }
      return loadingPromise;
    }
    var start = function () {
      requested = true;
      if (!playground?.ready) {
        hint.textContent = hint.dataset.loading;
        field.setAttribute("aria-busy", "true");
      }
      preload().then(reveal);
    };
    field.addEventListener("click", start);
    field.addEventListener("keydown", function (event) {
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        start();
      }
    });
    if ("requestIdleCallback" in window) window.requestIdleCallback(preload, { timeout: 1500 });
    else setTimeout(preload, 0);

    async function load() {
      var mod = await import("./playground.js");
      var assets = demo.dataset.assets || "./";
      await new Promise(function (resolve, reject) {
        playground = new mod.MisstypePlayground({
          container: host,
          wasmUrl: assets + "misstype.wasm",
          lexiconUrl: assets + "lexicon.tsv",
          tonelessUrl: assets + "toneless.tsv",
          englishUrl: assets + "english.tsv",
          onReady: resolve,
          onError: reject
        });
        playground.init();
      });
    }
  }

  function animate() {
    var examples = Array.prototype.map.call(items, function (li) {
      return {
        keys: Array.from(li.dataset.keys),
        got: li.querySelector(".got").textContent,
        what: li.querySelector(".what").innerHTML,
        typed: li.querySelector(".typed").innerHTML
      };
    });

    var caret = '<span class="caret"></span>';
    var index = 0;

    function show(html) { if (!stopped) field.innerHTML = html + caret; }
    function wait(ms) { return new Promise(function (r) { setTimeout(r, reduced ? Math.min(ms, 45) : ms); }); }

    async function play(ex) {
      caption.innerHTML = "<span>" + ex.what + "</span><span>" + ex.typed + "</span>";
      show("");
      await wait(500);
      for (var i = 1; i <= ex.keys.length && !stopped; i++) {
        show('<span class="composing">' + ex.keys.slice(0, i).join("") + "</span>");
        await wait(110 + Math.random() * 70);
      }
      await wait(350);
      show('<span class="composing">' + ex.got + "</span>");
      await wait(900);
      show('<span class="done">' + ex.got + "</span>");
      await wait(2200);
    }

    (async function () {
      while (!stopped) {
        await play(examples[index]);
        index = (index + 1) % examples.length;
      }
    })();
  }
})();
