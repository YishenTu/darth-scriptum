(() => {
  "use strict";

  const baseURL = "http://127.0.0.1:__LOOPBACK_PORT__";
  window.__hostileWindowWasDenied = window.open(
    `${baseURL}/remote-window`,
    "hostile-window"
  ) === null;

  Promise.allSettled([
    fetch(`${baseURL}/remote-fetch`, {cache: "no-store"})
  ]).finally(() => {
    window.__hostileAttemptsComplete = true;
  });
})();
