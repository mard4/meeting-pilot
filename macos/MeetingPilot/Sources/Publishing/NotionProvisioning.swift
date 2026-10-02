import AppKit
import ApplicationServices
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreGraphics
import FoundationModels
import Speech
import ServiceManagement
import SwiftUI
import UserNotifications


enum NotionProjectAssigner {
    static func assign(sessionDirectory: URL, values: [String], token: String, databaseID: String, propertyName: String, metadataKey: String, metadataFilename: String, receiptKey: String) -> Result<Void, Error> {
        do {
            guard !token.isEmpty else { throw NotionProjectError("Collega Meeting Pilot a Notion tramite il pulsante di autorizzazione OAuth.") }
            guard !databaseID.isEmpty else { throw NotionProjectError("Crea prima lo spazio Meeting Pilot in Notion.") }
            let receiptURL = sessionDirectory.appendingPathComponent("notion_receipt.json")
            guard let data = try? Data(contentsOf: receiptURL),
                  var receipt = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pageID = receipt["id"] as? String, !pageID.isEmpty else {
                throw NotionProjectError("Non trovo la pagina Notion associata a questa riunione.")
            }
            let db = try request(token: token, method: "GET", path: "/v1/databases/\(cleanID(databaseID))")
            let sourceID = ((db["data_sources"] as? [[String: Any]])?.first?["id"] as? String) ?? cleanID(databaseID)
            let source = try request(token: token, method: "GET", path: "/v1/data_sources/\(sourceID)")
            let schemaProperties = source["properties"] as? [String: Any] ?? [:]
            let propertySchema = schemaProperties[propertyName] as? [String: Any]
            let propertyType = propertySchema?["type"] as? String
            if propertySchema == nil {
                let initialName = String((values.first ?? "").prefix(100))
                _ = try request(token: token, method: "PATCH", path: "/v1/data_sources/\(sourceID)", body: ["properties": [propertyName: ["select": ["options": [["name": initialName, "color": "blue"]]]]]])
            }
            let names = values.map { String($0.prefix(100)) }.filter { !$0.isEmpty }
            guard let name = names.first else { throw NotionProjectError("Il tag non può essere vuoto.") }
            let propertyValue: [String: Any]
            switch propertyType {
            case "multi_select":
                propertyValue = ["multi_select": names.map { ["name": $0] }]
            case "select", nil:
                propertyValue = ["select": ["name": name]]
            default:
                throw NotionProjectError("La proprietà Notion \(propertyName) deve essere di tipo Select o Multi-select.")
            }
            _ = try request(token: token, method: "PATCH", path: "/v1/pages/\(pageID)", body: ["properties": [propertyName: propertyValue]])
            receipt[receiptKey] = name
            receipt["\(receiptKey)s"] = names
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL, options: .atomic)
            let metadata: [String: Any] = [metadataKey: name, "\(metadataKey)s": names, "notion_page_id": pageID, "updated_at": ISO8601DateFormatter().string(from: Date())]
            try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: sessionDirectory.appendingPathComponent(metadataFilename), options: .atomic)
            return .success(())
        } catch { return .failure(error) }
    }

    private static func request(token: String, method: String, path: String, body: [String: Any]? = nil) throws -> [String: Any] {
        guard let url = URL(string: "https://api.notion.com\(path)") else { throw NotionProjectError("URL Notion non valido.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-11", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<(Data, HTTPURLResponse), Error>!
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error { outcome = .failure(error) }
            else if let data, let response = response as? HTTPURLResponse { outcome = .success((data, response)) }
            else { outcome = .failure(NotionProjectError("Risposta Notion non valida.")) }
        }.resume()
        guard semaphore.wait(timeout: .now() + 30) == .success else { throw NotionProjectError("Notion non risponde: riprova.") }
        let (data, response) = try outcome.get()
        guard (200...299).contains(response.statusCode) else {
            let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let message = payload["message"] as? String ?? String(format: localized("Errore HTTP %ld"), response.statusCode)
            if response.statusCode == 404 && message.localizedCaseInsensitiveContains("shared") {
                throw NotionProjectError("La connessione OAuth di Meeting Pilot non ha accesso alla tabella o alla pagina della riunione. In Notion condividi la destinazione scelta con la connessione Meeting Pilot, poi riprova.")
            }
            throw NotionProjectError("Notion: \(message)")
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func cleanID(_ value: String) -> String { value.replacingOccurrences(of: "-", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct NotionProjectError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct NotionPageChoice: Codable, Hashable, Identifiable {
    let id: String
    let title: String

    private static let defaultsKey = "MeetingPilotNotionPageChoices"

    static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func loadSaved() -> [NotionPageChoice] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return [] }
        return (try? JSONDecoder().decode([NotionPageChoice].self, from: data)) ?? []
    }

    static func save(_ choices: [NotionPageChoice]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(choices), forKey: defaultsKey)
    }
}
