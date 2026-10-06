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


struct ContentPane<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                MPPageHeader(title: title, subtitle: subtitle)
                    .padding(.bottom, 6)
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: 1080, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(localized(text))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(MeetingPilotDesign.textDimColor)
    }
}

struct EditableField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: label)
            TextField(localized(placeholder), text: $text)
                .textFieldStyle(DarkTextFieldStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mpCard(padding: 14, radius: 14)
    }
}

struct MultilineEditableField: View {
    let label: String
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: label)
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(localized(placeholder))
                        .font(.system(size: 13))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                }
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(6)
                    .frame(minHeight: 150)
            }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MeetingPilotDesign.fieldColor))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(focused ? MeetingPilotDesign.accent.opacity(0.7) : MeetingPilotDesign.lineStrongColor, lineWidth: 1)
            )
            .animation(.mpSmooth, value: focused)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mpCard(padding: 14, radius: 14)
    }
}

struct SecureEditableField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FieldLabel(text: label)
            SecureField(localized(placeholder), text: $text)
                .textFieldStyle(DarkTextFieldStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mpCard(padding: 14, radius: 14)
    }
}

struct DarkTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MeetingPilotDesign.fieldColor))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MeetingPilotDesign.lineStrongColor, lineWidth: 1))
    }
}

struct SettingsRow: View {
    let label: String
    let value: String
    var detail: String? = nil
    var assetName: String? = nil
    var fallbackSymbol: String = "doc.text"
    var iconSize: CGFloat = 30
    var iconTemplateRendering: Bool = false
    var iconNeedsLightBackground: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if assetName != nil {
                BundledAssetIcon(
                    name: assetName,
                    fallbackSymbol: fallbackSymbol,
                    size: min(iconSize, 24),
                    templateRendering: iconTemplateRendering
                )
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(iconNeedsLightBackground ? Color.white : MeetingPilotDesign.hoverColor)
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                MPEyebrow(label)
                Text(localized(value))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MeetingPilotDesign.textColor)
                    .textSelection(.enabled)
                if let detail, !detail.isEmpty {
                    Text(localized(detail))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mpCard(padding: 14, radius: 14)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MPPrimaryButtonStyle().makeBody(configuration: configuration)
    }
}

/// Edits the glossary file format ("term, misheard variant, …" per line) as a two-column table,
/// so correct spellings and the mistakes they replace are never confused.
struct GlossaryTableEditor: View {
    @Binding var text: String
    @State private var rows: [GlossaryRow] = []

    struct GlossaryRow: Identifiable, Equatable {
        let id = UUID()
        var term = ""
        var variants = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(localized("Scrivi il termine corretto e, se vuoi, come viene storpiato in trascrizione. Le varianti vengono sostituite automaticamente."))
                .font(MPFont.callout())
                .foregroundStyle(MeetingPilotDesign.textDimColor)
                .fixedSize(horizontal: false, vertical: true)

            if !rows.isEmpty {
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        MPEyebrow("Termine corretto").frame(width: 190, alignment: .leading)
                        MPEyebrow("Varianti da correggere").frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(width: 28, height: 1)
                    }
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField(localized("es. isycontrol"), text: $row.term)
                                .textFieldStyle(DarkTextFieldStyle())
                                .frame(width: 190)
                            TextField(localized("es. isi control, easy control"), text: $row.variants)
                                .textFieldStyle(DarkTextFieldStyle())
                            Button {
                                rows.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(MPIconButtonStyle(size: 28))
                            .help(localized("Rimuovi termine"))
                        }
                    }
                }
            }

            Button {
                rows.append(GlossaryRow())
            } label: {
                Label(localized("Aggiungi termine"), systemImage: "plus")
            }
            .buttonStyle(CompactButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .mpCard(padding: 14, radius: 14)
        .onAppear { rows = Self.parse(text) }
        // Reload only for outside changes; our own edits already match `serialize(rows)`.
        .onChange(of: text) { value in
            if value != Self.serialize(rows) { rows = Self.parse(value) }
        }
        .onChange(of: rows) { value in
            let serialized = Self.serialize(value)
            if serialized != text { text = serialized }
        }
    }

    private static func parse(_ text: String) -> [GlossaryRow] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let term = parts.first else { return nil }
            return GlossaryRow(term: term, variants: parts.dropFirst().joined(separator: ", "))
        }
    }

    private static func serialize(_ rows: [GlossaryRow]) -> String {
        rows.compactMap { row in
            // Commas separate variants in the file, so they cannot be part of the term itself.
            let term = row.term.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { return nil }
            let variants = row.variants.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return ([term] + variants).joined(separator: ", ")
        }
        .joined(separator: "\n")
    }
}
