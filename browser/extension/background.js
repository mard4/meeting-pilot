// "Send to Meeting Pilot" in the right-click menu of YouTube pages and links. The popup does
// the same for the open tab; here the result shows on the toolbar icon for a few seconds.

importScripts("common.js");

const YOUTUBE_PATTERNS = [
  "https://www.youtube.com/*",
  "https://youtube.com/*",
  "https://m.youtube.com/*",
  "https://music.youtube.com/*",
  "https://youtu.be/*",
];

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: "send-page",
      title: chrome.i18n.getMessage("sendToApp"),
      contexts: ["page", "video"],
      documentUrlPatterns: YOUTUBE_PATTERNS,
    });
    chrome.contextMenus.create({
      id: "send-link",
      title: chrome.i18n.getMessage("sendLinkToApp"),
      contexts: ["link"],
      targetUrlPatterns: YOUTUBE_PATTERNS,
    });
  });
});

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const url = info.menuItemId === "send-link" ? info.linkUrl : info.pageUrl;
  if (!isYouTubeVideo(url)) {
    showResult(tab, "!", "#b3261e", chrome.i18n.getMessage("error_not_a_video"));
    return;
  }
  const reply = await sendToApp({ type: "import", url });
  if (reply.ok) {
    showResult(tab, "✓", "#2e7d32", chrome.i18n.getMessage("queued"));
  } else if (reply.error === "already_imported") {
    // Importing again is a choice made in the popup, where the date is shown.
    showResult(tab, "=", "#6b6b6b", chrome.i18n.getMessage("alreadyImportedShort"));
  } else {
    showResult(tab, "!", "#b3261e", errorText(reply));
  }
});

function showResult(tab, text, color, title) {
  const target = tab?.id === undefined ? {} : { tabId: tab.id };
  chrome.action.setBadgeBackgroundColor({ ...target, color });
  chrome.action.setBadgeText({ ...target, text });
  chrome.action.setTitle({ ...target, title });
  setTimeout(() => {
    chrome.action.setBadgeText({ ...target, text: "" });
    chrome.action.setTitle({ ...target, title: chrome.i18n.getMessage("extensionName") });
  }, 5000);
}
