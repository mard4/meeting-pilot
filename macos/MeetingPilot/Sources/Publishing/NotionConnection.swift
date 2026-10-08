import AppKit
import AuthenticationServices
import Foundation

/// Notion sign-in (OAuth via the Cloudflare worker), destination provisioning and the
/// "published to Notion" notifications.
final class NotionConnection: ObservableObject {
    @Published var token = ""
    @Published var parentPageId = ""
    /// Pages shared during the last Notion sign-in, so the user can pick the parent.
    @Published var pageChoices: [NotionPageChoice] = NotionPageChoice.loadSaved()
    @Published var appPageId = ""
    @Published var seriesDatabaseId = ""
    @Published var occurrencesDatabaseId = ""
    @Published var pageName = "Meeting Pilot"

    var onStatusMessage: (String) -> Void = { _ in }
    var onNeedsRefresh: () -> Void = {}

    private let envURL: URL
    private var knownReceiptPaths: Set<String>?
    /// The sign-in in progress. Its state lives only in memory and is used once: kept in
    /// `.env`, which any process can write, it would let a callback with someone else's
    /// token through, and every meeting would then be published to their workspace.
    private var pendingOAuthState: String?
    private var authSession: ASWebAuthenticationSession?
    private let authPresentation = OAuthPresentation()

    init(envURL: URL) {
        self.envURL = envURL
    }

    var isConnected: Bool {
        !token.isEmpty && !occurrencesDatabaseId.isEmpty
    }

    var parentPageTitle: String? {
        let id = NotionPageChoice.normalized(parentPageId)
        return pageChoices.first { NotionPageChoice.normalized($0.id) == id }?.title
    }

    func load(from env: [String: String]) {
        token = env["NOTION_TOKEN"] ?? ""
        parentPageId = env["NOTION_PARENT_PAGE_ID"] ?? ""
        appPageId = env["NOTION_APP_PAGE_ID"] ?? ""
        seriesDatabaseId = env["NOTION_SERIES_DATABASE_ID"] ?? ""
        let configuredOccurrences = env["NOTION_OCCURRENCES_DATABASE_ID"] ?? ""
        occurrencesDatabaseId = configuredOccurrences.isEmpty ? (env["NOTION_DATABASE_ID"] ?? "") : configuredOccurrences
        let configuredPageName = (env["NOTION_PAGE_NAME"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pageName = configuredPageName.isEmpty ? "Meeting Pilot" : configuredPageName
    }

    func saveSettings(token: String, parentPageId: String, pageName: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParentPageId = parentPageId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPageName = pageName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPageName.isEmpty else {
            onStatusMessage("Inserisci il nome della pagina Notion")
            return
        }
        let destinationChanged = trimmedPageName.caseInsensitiveCompare(self.pageName) != .orderedSame
            || (!trimmedParentPageId.isEmpty && trimmedParentPageId != self.parentPageId)
        if destinationChanged {
            resetDestinationForWorkspaceSwitch()
        }
        persistSettings(
            token: trimmedToken,
            parentPageId: trimmedParentPageId,
            pageName: trimmedPageName
        )
        if !trimmedToken.isEmpty && !trimmedParentPageId.isEmpty {
            provisionWorkspace(
                token: trimmedToken,
                parentPageId: trimmedParentPageId,
                pageName: trimmedPageName
            )
            return
        }
        onStatusMessage("Notion salvato")
        onNeedsRefresh()
    }

    func provisionWorkspace(token: String, parentPageId: String, pageName: String? = nil) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedParentPageId = parentPageId.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationName = (pageName ?? self.pageName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            onStatusMessage("Inserisci il token dell'integrazione Notion")
            return
        }
        guard !trimmedParentPageId.isEmpty || !appPageId.isEmpty else {
            onStatusMessage("Incolla URL o ID della pagina Notion parent")
            return
        }
        guard !destinationName.isEmpty else {
            onStatusMessage("Inserisci il nome della pagina Notion")
            return
        }
        persistSettings(
            token: trimmedToken,
            parentPageId: trimmedParentPageId,
            pageName: destinationName
        )
        onStatusMessage("Controllo destinazione Notion...")
        let existingAppPageID = appPageId
        let existingOccurrencesDatabaseID = occurrencesDatabaseId
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try NativeNotionProvisioner.provision(
                    token: trimmedToken,
                    parentPageID: trimmedParentPageId,
                    existingAppPageID: existingAppPageID,
                    existingOccurrencesDatabaseID: existingOccurrencesDatabaseID,
                    destinationName: destinationName
                )
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let workspace):
                    EnvFile.update(
                        at: self.envURL,
                        values: [
                            "NOTION_APP_PAGE_ID": workspace.appPageID,
                            "NOTION_SERIES_DATABASE_ID": "",
                            "NOTION_OCCURRENCES_DATABASE_ID": workspace.occurrencesDatabaseID,
                            "NOTION_DATABASE_ID": workspace.occurrencesDatabaseID,
                            "NOTION_PAGE_NAME": destinationName,
                            "NOTION_TITLE_PROPERTY": "Name",
                            "NOTION_PROJECT_PROPERTY": "Project"
                        ]
                    )
                    if let parentTitle = self.parentPageTitle {
                        self.onStatusMessage(workspace.reusedDestination
                            ? "Pagina già esistente, collegata a: \(parentTitle)"
                            : "Pagina creata e collegata a: \(parentTitle)")
                    } else {
                        self.onStatusMessage(workspace.reusedDestination
                            ? "Pagina già esistente, collegata"
                            : "Pagina creata e collegata")
                    }
                case .failure(let error):
                    self.onStatusMessage("Errore Notion: \(error.localizedDescription)")
                }
                self.onNeedsRefresh()
            }
        }
    }

    /// The token comes back in a `meetingpilot://` URL. The authentication session catches
    /// it itself, so it never goes through Launch Services, where another app registering
    /// the same scheme could receive it.
    func startOAuth() {
        let state = UUID().uuidString
        guard let url = URL(string: "https://meeting-pilot-oauth.c59nm9zsd7.workers.dev/notion/start?state=\(state)") else { return }
        pendingOAuthState = state
        EnvFile.remove(at: envURL, keys: ["NOTION_OAUTH_STATE"])
        authSession?.cancel()
        let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "meetingpilot") { [weak self] callback, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authSession = nil
                if let callback {
                    self.handleOAuthCallback(callback)
                } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                    self.pendingOAuthState = nil
                    self.onStatusMessage("Collegamento a Notion annullato.")
                } else if let error {
                    self.pendingOAuthState = nil
                    self.onStatusMessage("Collegamento a Notion non riuscito: \(error.localizedDescription)")
                }
            }
        }
        session.presentationContextProvider = authPresentation
        authSession = session
        onStatusMessage("Apro Notion per il collegamento...")
        if !session.start() {
            authSession = nil
            pendingOAuthState = nil
            onStatusMessage("Non riesco ad aprire Notion per il collegamento.")
        }
    }

    func handleOAuthCallback(_ url: URL) {
        guard url.scheme == "meetingpilot",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let callbackState = values["state"] ?? ""
        // Accept callbacks produced by both Worker HTML versions. In the older
        // version, HTML escaping could prefix these parameter names with "amp;".
        let token = values["access_token"] ?? values["amp;access_token"] ?? ""
        let parent = values["parent_page_id"] ?? values["amp;parent_page_id"] ?? ""
        let parentTitle = values["parent_page_title"] ?? ""
        var choices = (values["pages"].flatMap { $0.data(using: .utf8) })
            .flatMap { try? JSONDecoder().decode([NotionPageChoice].self, from: $0) } ?? []
        if choices.isEmpty, !parent.isEmpty, !parentTitle.isEmpty {
            choices = [NotionPageChoice(id: parent, title: parentTitle)]
        }

        guard let expectedState = pendingOAuthState, !callbackState.isEmpty, callbackState == expectedState else {
            onStatusMessage("Sessione Notion scaduta: riprova il collegamento.")
            return
        }
        pendingOAuthState = nil
        guard !token.isEmpty else {
            onStatusMessage("Notion non ha restituito il token: riprova il collegamento.")
            return
        }
        guard !parent.isEmpty else {
            onStatusMessage("In Notion seleziona almeno una pagina, poi riprova.")
            return
        }
        pageChoices = choices
        NotionPageChoice.save(choices)
        parentPageId = parent
        persistSettings(token: token, parentPageId: parent, pageName: pageName)
        resetDestinationForWorkspaceSwitch()
        onStatusMessage("Notion collegato: controllo la destinazione...")
        provisionWorkspace(token: token, parentPageId: parent, pageName: pageName)
    }

    func chooseParentPage(_ choice: NotionPageChoice) {
        guard NotionPageChoice.normalized(choice.id) != NotionPageChoice.normalized(parentPageId) else { return }
        parentPageId = choice.id
        resetDestinationForWorkspaceSwitch()
        provisionWorkspace(token: token, parentPageId: choice.id, pageName: pageName)
    }

    func openDatabase() {
        let env = EnvFile.load(from: envURL)
        guard let id = env["NOTION_APP_PAGE_ID"] ?? env["NOTION_OCCURRENCES_DATABASE_ID"] ?? env["NOTION_DATABASE_ID"], !id.isEmpty else { return }
        let clean = id.replacingOccurrences(of: "-", with: "")
        if let url = URL(string: "https://notion.so/\(clean)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openTokenPage() {
        if let url = URL(string: "https://www.notion.so/developers/tokens") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The first call only records existing receipts, so launching the app doesn't
    /// re-announce every meeting already published.
    func notifyForNewPublications(in doneRoot: URL) {
        let sessions = (try? FileManager.default.contentsOfDirectory(
            at: doneRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let receipts = Set(sessions.compactMap { session -> String? in
            let receipt = session.appendingPathComponent("notion_receipt.json")
            return FileManager.default.fileExists(atPath: receipt.path) ? receipt.path : nil
        })

        guard let known = knownReceiptPaths else {
            knownReceiptPaths = receipts
            return
        }

        for path in receipts.subtracting(known).sorted() {
            let session = URL(fileURLWithPath: path).deletingLastPathComponent()
            let metadata = readJSON(session.appendingPathComponent("meeting_metadata.json"))
            let summary = readJSON(session.appendingPathComponent("omlx_summary.json"))
            let title = (summary["title"] as? String)
                ?? (metadata["title"] as? String)
                ?? session.lastPathComponent
            NotificationBridge.showNotionPublished(title: title)
        }
        knownReceiptPaths = receipts
    }

    private func persistSettings(token: String, parentPageId: String, pageName: String) {
        EnvFile.update(
            at: envURL,
            values: [
                "NOTION_TOKEN": token,
                "NOTION_PARENT_PAGE_ID": parentPageId,
                "NOTION_PAGE_NAME": pageName
            ]
        )
    }

    private func resetDestinationForWorkspaceSwitch() {
        EnvFile.update(
            at: envURL,
            values: [
                "NOTION_APP_PAGE_ID": "",
                "NOTION_SERIES_DATABASE_ID": "",
                "NOTION_OCCURRENCES_DATABASE_ID": "",
                "NOTION_DATABASE_ID": ""
            ]
        )
        appPageId = ""
        seriesDatabaseId = ""
        occurrencesDatabaseId = ""
    }
}

/// Shows the Notion sign-in sheet over the app's window, or on its own when none is open.
private final class OAuthPresentation: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }
}
