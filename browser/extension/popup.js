const $ = (id) => document.getElementById(id);
const t = (key, substitutions) => chrome.i18n.getMessage(key, substitutions);

// Hyphenation follows the language: "Zusammenfassung" must break, not overflow.
document.documentElement.lang = chrome.i18n.getUILanguage();

for (const element of document.querySelectorAll("[data-i18n]")) {
  element.textContent = t(element.dataset.i18n);
}

const STEPS = ["download", "transcribe", "summarize", "publish"];
const RING_ICON = { done: "i-tick", queued: "i-clock", failed: "i-bang", active: "i-tick" };
// The app reads the video's title before it starts downloading: until the download shows
// up, a video just sent is still "downloading".
const SEND_GRACE_MS = 120_000;

let tabUrl = "";
let sentAt = 0;

init();

async function init() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  tabUrl = tab?.url || "";
  const id = youTubeVideoID(tabUrl);
  $("video").hidden = !id;
  $("not-video").hidden = Boolean(id);
  if (id) {
    $("thumb").src = `https://i.ytimg.com/vi/${id}/mqdefault.jpg`;
    $("thumb").onerror = () => $("thumb").remove();
    $("video-title").textContent = (tab.title || "").replace(/ - YouTube$/, "");
  }

  const [hello, status] = await Promise.all([
    sendToApp({ type: "hello" }),
    id ? sendToApp({ type: "status", url: tabUrl }) : Promise.resolve(null),
  ]);
  if (reloadIfUpdated(hello)) return;
  const ready = hello.ok && hello.configured;
  $("connection").className = `connection ${ready ? "ready" : "missing"}`;
  $("connection-text").textContent = t(ready ? "statusReady" : "statusMissing");
  if (!id) return;
  if (!ready) {
    showSetup();
  } else if (status?.ok && status.state !== "none") {
    showPipeline(status);
  } else {
    $("send").hidden = false;
  }
}

$("send").addEventListener("click", () => send(false));
$("again-pipeline").addEventListener("click", () => send(true));

// Without the native host the app is reached through its URL scheme; it then opens the
// import sheet with the link instead of importing straight away.
$("fallback").addEventListener("click", () => {
  chrome.tabs.update({ url: `meetingpilot://import?url=${encodeURIComponent(tabUrl)}` });
  window.close();
});

async function send(force) {
  $("send").disabled = true;
  $("again-pipeline").hidden = true;
  const reply = await sendToApp({ type: "import", url: tabUrl, force });
  $("send").disabled = false;
  if (reply.ok) {
    sentAt = Date.now();
    $("send").hidden = true;
    $("result").hidden = true;
    showPipeline({ step: "download", state: "active" });
  } else if (reply.error === "already_imported") {
    $("send").hidden = true;
    showPipeline(await sendToApp({ type: "status", url: tabUrl }));
  } else if (reply.error === "host_missing" || reply.error === "not_configured") {
    showSetup();
  } else {
    showResult("warn", "i-alert", t("notSent"), errorText(reply));
  }
}

/** Rings before the current step are done, the current one shows its state, later ones wait. */
function showPipeline(status) {
  const finished = status.state === "done";
  const current = finished ? STEPS.length : Math.max(STEPS.indexOf(status.step), 0);
  for (const [index, item] of [...$("pipeline").children].entries()) {
    const state = index < current ? "done" : index === current ? status.state : "pending";
    item.className = state;
    item.querySelector("use").setAttribute("href", `#${RING_ICON[state] || "i-tick"}`);
  }
  $("pipeline").hidden = false;
  $("again-pipeline").hidden = !(finished || status.state === "failed");

  const working = status.state === "active" || status.state === "queued";
  if (working) setTimeout(refresh, 1500);
}

async function refresh() {
  const status = await sendToApp({ type: "status", url: tabUrl });
  if (!status.ok) return;
  if (status.state === "none" && Date.now() - sentAt < SEND_GRACE_MS) {
    showPipeline({ step: "download", state: "active" });
  } else if (status.state !== "none") {
    showPipeline(status);
  }
}

function showResult(tone, icon, word, detail) {
  $("result").className = `result ${tone}`;
  $("result-icon").firstElementChild.setAttribute("href", `#${icon}`);
  $("result-word").textContent = word;
  $("result-detail").textContent = detail;
  $("result-detail").hidden = !detail;
  $("result").hidden = false;
}

function showSetup() {
  $("send").hidden = true;
  $("setup").hidden = false;
  $("fallback").hidden = !isYouTubeVideo(tabUrl);
}

/**
 * Loaded unpacked, the extension runs the files as the browser read them; when the app has
 * put a newer copy in their folder, it reloads itself (and this popup closes). The store's
 * copy updates on its own. localStorage needs no permission and lasts across reloads.
 */
function reloadIfUpdated(hello) {
  if (chrome.runtime.getManifest().update_url || !hello.extension_stamp) return false;
  let seen = null;
  try {
    seen = localStorage.getItem("extensionStamp");
    localStorage.setItem("extensionStamp", hello.extension_stamp);
  } catch {
    return false;
  }
  if (seen === null || seen === hello.extension_stamp) return false;
  chrome.runtime.reload();
  return true;
}
