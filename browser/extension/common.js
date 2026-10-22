// Shared by the service worker (importScripts) and the popup (<script>).

const NATIVE_HOST = "com.meetingpilot.browser";

/** The id of a single YouTube video, or null; the app checks the link again before importing. */
function youTubeVideoID(url) {
  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const host = parsed.hostname.replace(/^(www|m|music)\./, "");
  const valid = (value) => (/^[A-Za-z0-9_-]{11}$/.test(value || "") ? value : null);
  if (host === "youtu.be") return valid(parsed.pathname.slice(1));
  if (host !== "youtube.com" && host !== "youtube-nocookie.com") return null;
  if (parsed.pathname === "/watch") return valid(parsed.searchParams.get("v"));
  const [, kind, value] = parsed.pathname.split("/");
  return ["shorts", "live", "embed", "v"].includes(kind) ? valid(value) : null;
}

function isYouTubeVideo(url) {
  return youTubeVideoID(url) !== null;
}

/**
 * One message to the Mac app through its native host. Resolves to the host's reply, or to
 * {ok: false, error: "host_missing"} when Meeting Pilot has not set the browser up.
 */
function sendToApp(message) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(NATIVE_HOST, { v: 1, ...message }, (reply) => {
      if (chrome.runtime.lastError || !reply) {
        resolve({ ok: false, error: "host_missing", detail: chrome.runtime.lastError?.message });
      } else {
        resolve(reply);
      }
    });
  });
}

/** The words for a host reply's error code. */
function errorText(reply) {
  const known = ["host_missing", "not_a_video", "not_configured", "app_unavailable"];
  return chrome.i18n.getMessage(known.includes(reply.error) ? `error_${reply.error}` : "error_unknown");
}
