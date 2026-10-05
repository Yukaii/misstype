// Plays the examples listed on the page in the fake text field at the top.
// The examples list is the single source: each <li> carries the keys that
// were typed (data-keys) and the text Misstype produced (.got). Without JS,
// or with reduced motion, the field keeps its static first example.
(function () {
  var field = document.querySelector(".field");
  var caption = document.querySelector(".demo .keys");
  var items = document.querySelectorAll(".examples li[data-keys]");
  if (!field || !caption || !items.length) return;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

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

  function show(html) { field.innerHTML = html + caret; }
  function wait(ms) { return new Promise(function (r) { setTimeout(r, ms); }); }

  async function play(ex) {
    caption.innerHTML = "<span>" + ex.what + "</span><span>" + ex.typed + "</span>";
    show("");
    await wait(500);
    for (var i = 1; i <= ex.keys.length; i++) {
      show('<span class="composing">' + ex.keys.slice(0, i).join("") + "</span>");
      await wait(110 + Math.random() * 70);
    }
    await wait(350);
    show('<span class="composing">' + ex.got + "</span>");
    await wait(900);
    show('<span class="done">' + ex.got + "</span>");
    await wait(2200);
  }

  async function loop() {
    for (;;) {
      await play(examples[index]);
      index = (index + 1) % examples.length;
    }
  }

  loop();
})();
