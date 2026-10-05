import AppKit
import PDFKit
import SwiftUI

/// Where a Diary page keeps its slides: `slides:` in the frontmatter names a PDF beside
/// the page (see `journal_publisher.py`).
func journalSlidesURL(for note: JournalNote, document: JournalDocument) -> URL? {
    guard let name = note.value("slides"), !name.hasPrefix("[[") else { return nil }
    let url = name.hasPrefix("/")
        ? URL(fileURLWithPath: name)
        : document.url.deletingLastPathComponent().appendingPathComponent(name)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
}

/// The part of the transcript spoken while one slide was shown. The slide it belongs to
/// opens next to it on click; the selected slide's part is highlighted and expanded.
struct SlideTranscriptBlock: View {
    let page: Int
    let title: String
    let lines: [String]
    let selected: Bool
    let onSelect: (() -> Void)?
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if selected {
                    withAnimation(.mpSnappy) { expanded.toggle() }
                } else {
                    onSelect?()
                    withAnimation(.mpSnappy) { expanded = true }
                }
            } label: {
                HStack(spacing: 10) {
                    Text("\(page)")
                        .font(MPFont.caption(.semibold, design: .monospaced))
                        .foregroundStyle(selected ? Color.white : MeetingPilotDesign.accent)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Circle().fill(selected ? MeetingPilotDesign.accent : MeetingPilotDesign.accentTint))
                    Text(title)
                        .font(MPFont.callout(.semibold))
                        .foregroundStyle(MeetingPilotDesign.textColor)
                        .lineLimit(1)
                    Spacer()
                    Text("\(lines.count) " + localized(lines.count == 1 ? "intervento" : "interventi"))
                        .font(MPFont.caption(design: .monospaced))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                    Image(systemName: "chevron.down")
                        .font(MPFont.caption(.semibold))
                        .foregroundStyle(MeetingPilotDesign.textFaintColor)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localized("Mostra la slide e quello che è stato detto"))

            if expanded {
                Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1)
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        let turn = transcriptTurn(line)
                        VStack(alignment: .leading, spacing: 2) {
                            if let speaker = turn.speaker {
                                Text(speaker)
                                    .font(MPFont.caption(.semibold))
                                    .foregroundStyle(MeetingPilotDesign.accent)
                            }
                            Text(turn.text)
                                .font(MPFont.body())
                                .foregroundStyle(MeetingPilotDesign.textColor)
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
                .textSelection(.enabled)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous).fill(MeetingPilotDesign.fieldColor))
        .overlay(
            RoundedRectangle(cornerRadius: MPRadius.panel, style: .continuous)
                .strokeBorder(selected ? MeetingPilotDesign.accent.opacity(0.6) : MeetingPilotDesign.lineColor, lineWidth: 1)
        )
        .onChange(of: selected) { _, isSelected in
            if isSelected { withAnimation(.mpSnappy) { expanded = true } }
        }
    }
}

/// The slides beside a Diary page. Paging through them reports the slide shown, so the
/// transcript can follow; a slide chosen in the transcript opens here.
struct JournalSlidesPane: View {
    let url: URL
    let page: Int?
    let onPageChange: (Int) -> Void
    @State private var shownPage = 1
    @State private var pageCount = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.richtext")
                    .foregroundStyle(MeetingPilotDesign.accent)
                Text(pageCount > 0 ? String(format: localized("Slide %d di %d"), shownPage, pageCount) : localized("Slide"))
                    .font(MPFont.callout(.semibold, design: .monospaced))
                Spacer()
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(MPIconButtonStyle(size: 26))
                .help(localized("Apri le slide in Anteprima"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Rectangle().fill(MeetingPilotDesign.lineColor).frame(height: 1)
            SlidePDFView(url: url, page: page) { current, count in
                shownPage = current
                pageCount = count
                // Opening on the first slide is not a choice, so the page stays where it is.
                if current != (page ?? 1) { onPageChange(current) }
            }
        }
    }
}

struct SlidePDFView: NSViewRepresentable {
    let url: URL
    let page: Int?
    /// The page now shown and the page count, after the user pages or a slide is chosen.
    let onShow: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onShow: onShow) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        DispatchQueue.main.async { context.coordinator.report(view) }
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.onShow = onShow
        if view.document?.documentURL != url {
            view.document = PDFDocument(url: url)
        }
        guard let page, let target = view.document?.page(at: page - 1), view.currentPage != target else { return }
        view.go(to: target)
    }

    static func dismantleNSView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    final class Coordinator: NSObject {
        var onShow: (Int, Int) -> Void

        init(onShow: @escaping (Int, Int) -> Void) {
            self.onShow = onShow
        }

        @objc func pageChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView else { return }
            report(view)
        }

        func report(_ view: PDFView) {
            guard let document = view.document, let page = view.currentPage else { return }
            onShow(document.index(for: page) + 1, document.pageCount)
        }
    }
}
