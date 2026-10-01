const CALLBACK = "https://meeting-pilot-oauth.c59nm9zsd7.workers.dev/notion/callback";

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/notion/start") {
      const authorize = new URL("https://api.notion.com/v1/oauth/authorize");
      authorize.search = new URLSearchParams({
        client_id: env.NOTION_CLIENT_ID,
        redirect_uri: CALLBACK,
        response_type: "code",
        owner: "user",
        state: url.searchParams.get("state") || "",
      }).toString();
      return Response.redirect(authorize.toString(), 302);
    }
    if (url.pathname !== "/notion/callback") return new Response("Meeting Pilot OAuth", { status: 200 });

    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state") || "";
    if (!code) return new Response("Notion did not return an authorization code.", { status: 400 });
    const credentials = btoa(`${env.NOTION_CLIENT_ID}:${env.NOTION_CLIENT_SECRET}`);
    const tokenResponse = await fetch("https://api.notion.com/v1/oauth/token", {
      method: "POST",
      headers: { Authorization: `Basic ${credentials}`, "Content-Type": "application/json" },
      body: JSON.stringify({ grant_type: "authorization_code", code, redirect_uri: CALLBACK }),
    });
    if (!tokenResponse.ok) return new Response("Notion authorization failed.", { status: 502 });
    const token = await tokenResponse.json();
    const search = await fetch("https://api.notion.com/v1/search", {
      method: "POST",
      headers: { Authorization: `Bearer ${token.access_token}`, "Notion-Version": "2026-03-11", "Content-Type": "application/json" },
      body: JSON.stringify({ filter: { property: "object", value: "page" }, page_size: 100 }),
    });
    const pages = sharedRootPages((await search.json()).results || []);
    const parent = pages[0];
    if (!parent) return new Response("Select at least one Notion page during authorization, then retry.", { status: 400 });
    const app = new URL("meetingpilot://notion/callback");
    app.search = new URLSearchParams({
      state,
      access_token: token.access_token,
      parent_page_id: parent.id,
      parent_page_title: parent.title,
      // The app lets the user switch between these when more than one was shared.
      pages: JSON.stringify(pages.slice(0, 20)),
    }).toString();
    const appURL = app.toString();
    const htmlURL = appURL.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
    return new Response(
      `<!doctype html><html><body><p>Notion collegato. Riapro Meeting Pilot…</p><script>location.href=${JSON.stringify(appURL)}</script><a href="${htmlURL}">Apri Meeting Pilot</a></body></html>`,
      { headers: { "Content-Type": "text/html; charset=UTF-8", "Cache-Control": "no-store" } },
    );
  },
};

// Search also returns every child of a shared page. Keep only the pages the user
// actually ticked during authorization (those whose parent isn't itself in the
// results), sorted by title so the default choice is stable instead of arbitrary.
function sharedRootPages(results) {
  const ids = new Set(results.map((page) => page.id));
  return results
    .filter((page) => !page.archived && !page.in_trash)
    .filter((page) => !ids.has(page.parent?.page_id))
    .map((page) => ({ id: page.id, title: pageTitle(page) }))
    .sort((a, b) => a.title.localeCompare(b.title));
}

function pageTitle(page) {
  const title = Object.values(page.properties || {}).find((property) => property.type === "title");
  const text = (title?.title || []).map((part) => part.plain_text).join("").trim();
  return text || "Untitled";
}
