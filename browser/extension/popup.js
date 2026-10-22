const $ = (id) => document.getElementById(id);
const t = (key, substitutions) => chrome.i18n.getMessage(key, substitutions);

for (const element of document.querySelectorAll("[data-i18n]")) {
  element.textContent = t(element.dataset.i18n);
}

let tabUrl = "";

init();

async function init() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  tabUrl = tab?.url || "";
  const id = youTubeVideoID(tabUrl);
  $("video").hidden = !id;
  $("send").hidden = !id;
  $("not-video").hidden = Boolean(id);
  if (id) {
    $("thumb").src = `https://i.ytimg.com/vi/${id}/mqdefault.jpg`;
    $("thumb").onerror = () => $("thumb").remove();
    $("video-title").textContent = (tab.title || "").replace(/ - YouTube$/, "");
  }

  const hello = await sendToApp({ type: "hello" });
  const ready = hello.ok && hello.configured;
  $("mac").className = `mac ${ready ? "ready" : "missing"}`;
  $("mac").title = t(ready ? "statusReady" : "statusMissing");
  $("mac").setAttribute("aria-label", $("mac").title);
  if (!ready) {
    // Sending would fail: the setup path takes the button's place.
    showSetup();
  }
}

$("send").addEventListener("click", () => send(false));
$("again").addEventListener("click", () => send(true));

// Without the native host the app is reached through its URL scheme; it then opens the
// import sheet with the link instead of importing straight away.
$("fallback").addEventListener("click", () => {
  chrome.tabs.update({ url: `meetingpilot://import?url=${encodeURIComponent(tabUrl)}` });
  window.close();
});

async function send(force) {
  $("send").disabled = true;
  $("again").hidden = true;
  const reply = await sendToApp({ type: "import", url: tabUrl, force });
  if (reply.ok) {
    // The one animation: the video goes to the Mac in the corner.
    const video = $("video");
    video.addEventListener("animationend", () => (video.hidden = true), { once: true });
    video.classList.add("sent");
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) video.hidden = true;
    $("send").hidden = true;
    showResult("ok", "i-check", t("queued"), $("video-title").textContent);
  } else if (reply.error === "already_imported") {
    const date = new Date(reply.imported_at);
    const when = isNaN(date) ? reply.imported_at : date.toLocaleDateString(chrome.i18n.getUILanguage(), { day: "numeric", month: "short" });
    $("send").hidden = true;
    showResult("again", "i-again", t("alreadyImportedShort"), t("importedOn", [when]));
    $("again").hidden = false;
  } else {
    $("send").disabled = false;
    if (reply.error === "host_missing" || reply.error === "not_configured") {
      showSetup();
    } else {
      showResult("warn", "i-alert", t("notSent"), errorText(reply));
    }
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
