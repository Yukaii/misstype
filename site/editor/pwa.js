// Offline support: the service worker (emitted by vite.config.js) precaches the
// page, the decoder and the lexicons, so the editor runs with no network.
export function registerServiceWorker(report) {
  if (!("serviceWorker" in navigator) || !import.meta.env.PROD) return;
  navigator.serviceWorker.register("./sw.js", { scope: "./", updateViaCache: "none" }).then((reg) => {
    const track = (worker) => worker?.addEventListener("statechange", () => {
      if (worker.state === "activated") report("可離線使用");
    });
    if (reg.active && !reg.installing) report("可離線使用");
    track(reg.installing);
    reg.addEventListener("updatefound", () => track(reg.installing));
    // An installed app can stay open for days and never navigate, so check for
    // a new worker when it comes back to the foreground.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") reg.update().catch(() => {});
    });
  }).catch((err) => {
    console.warn("service worker unavailable", err);
    report("");
  });
}
