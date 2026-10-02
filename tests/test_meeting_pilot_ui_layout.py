from pathlib import Path
import unittest


SOURCES_DIR = Path(__file__).parents[1] / "macos/MeetingPilot/Sources"


class _AppSources:
    """The app used to live in a single MeetingPilot.swift; read all split files as one."""

    def read_text(self) -> str:
        return FILE_BREAK.join(path.read_text() for path in sorted(SOURCES_DIR.rglob("*.swift")))


FILE_BREAK = "\n// ---- next source file ----\n"


def _section(source: str, start: str, end: str) -> str:
    """Text from `start` up to the next `end` in the same file (or the end of that file)."""
    begin = source.index(start)
    file_end = source.find(FILE_BREAK, begin)
    limit = len(source) if file_end == -1 else file_end
    stop = source.find(end, begin + len(start), limit)
    return source[begin:limit if stop == -1 else stop]


SOURCE = _AppSources()
APPLE_TRANSCRIBER = Path(__file__).parents[1] / "macos/MeetingPilot/Sources/Transcription/AppleTranscriber.swift"
INFO_PLIST = Path(__file__).parents[1] / "macos/MeetingPilot/Info.plist"


class MeetingPilotUILayoutTests(unittest.TestCase):
    def test_pipeline_connectors_only_light_after_completed_steps(self):
        source = SOURCE.read_text()
        pipeline = _section(source, "struct PipelineProgress", "struct StepDot")

        self.assertIn("done: step.state != .pending", pipeline)
        self.assertIn("MeetingPilotDesign.success.opacity(0.7)", pipeline)
        self.assertIn("MeetingPilotDesign.lineStrongColor", pipeline)

    def test_empty_today_meetings_state_explains_what_will_appear(self):
        source = SOURCE.read_text()
        meetings = _section(source, "struct RecentMeetingsList", "struct HistoryView")

        self.assertIn('Image(systemName: "calendar.badge.clock")', meetings)
        self.assertIn("Le riunioni rilevate dal calendario o registrate manualmente appariranno qui.", meetings)

    def test_pipeline_card_only_appears_while_something_is_moving(self):
        source = SOURCE.read_text()
        dashboard = _section(source, "struct DashboardView", "struct StatTile")
        card = _section(source, "struct PipelineCard", "struct ProcessingQueueList")

        self.assertIn("if PipelineCard.isRelevant(model)", dashboard)
        self.assertIn("static func isRelevant(_ model: AppModel) -> Bool", card)
        self.assertIn("model.queueCount > 0", card)
        self.assertIn("!model.processingSessions.isEmpty", card)

    def test_light_theme_is_persistent_and_available_in_settings(self):
        source = SOURCE.read_text()
        settings = _section(source, "struct SettingsOverviewView", "struct LaunchAtLoginCard")
        picker = _section(source, "struct ThemeIconPicker", "struct SettingsOverviewView")

        self.assertIn("@Published var appTheme", source)
        self.assertIn('forKey: "MeetingPilotAppTheme"', source)
        self.assertIn('Text(localized("Tema app"))', settings)
        self.assertIn("ThemeIconPicker(selection:", settings)
        self.assertIn("model.saveAppTheme($0)", settings)
        self.assertIn('themeButton(.light, symbol: "sun.max.fill", label: "Chiaro")', picker)
        self.assertIn(".preferredColorScheme(model.appTheme == .light ? .light : .dark)", source)

    def test_app_opens_a_visible_main_window_on_launch(self):
        source = SOURCE.read_text()
        delegate = _section(source, "final class AppDelegate", "enum AppSection")
        app = _section(source, "struct MeetingPilotApp", "final class AppDelegate")

        self.assertIn('WindowGroup("Meeting Pilot")', app)
        self.assertIn(".environmentObject(appDelegate.model)", app)
        self.assertIn("private var mainWindow: NSWindow?", delegate)
        self.assertIn("let model = AppModel()", delegate)
        self.assertIn("showMainWindow()", delegate)
        self.assertIn("mainWindow?.makeKeyAndOrderFront(nil)", delegate)
        self.assertIn("applicationShouldHandleReopen", delegate)
        self.assertIn("mainWindow?.orderFrontRegardless()", delegate)
        self.assertIn("NSApp.setActivationPolicy(.regular)", delegate)
        # `.accessory` is only allowed in the DEBUG-only snapshot renderer.
        release_launch = delegate[delegate.index("#endif"):]
        self.assertNotIn("NSApp.setActivationPolicy(.accessory)", release_launch)
        self.assertNotIn("LSUIElement", INFO_PLIST.read_text())

    def test_app_keeps_a_visible_menu_bar_item(self):
        source = SOURCE.read_text()
        delegate = _section(source, "final class AppDelegate", "enum AppSection")

        self.assertIn("NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)", delegate)
        self.assertNotIn('button.title = "MP"', delegate)
        self.assertIn("NSImage.meetingPilotAppIcon()", delegate)
        # The brand mark is drawn as a template image so it follows the menu bar appearance.
        self.assertIn("BrandMarkGeometry.templateImage(pointSize: 18)", source)
        self.assertIn("button.imagePosition = .imageOnly", delegate)
        self.assertIn("#selector(togglePopover(_:))", delegate)
        self.assertNotIn("addGlobalMonitorForEvents", delegate)

    def test_sidebar_uses_the_app_logo_asset(self):
        source = SOURCE.read_text()
        sidebar = _section(source, "struct Sidebar", "struct DashboardView")

        self.assertNotIn('BundledAssetIcon(name: "AppIcon.png", fallbackSymbol: "square", size: 20)', sidebar)
        self.assertNotIn('Image(systemName: "square")', sidebar)

    def test_sidebar_rows_pair_a_system_icon_with_a_label(self):
        source = SOURCE.read_text()
        sidebar = _section(source, "struct Sidebar", "private struct SidebarStatusFooter")

        self.assertIn("BrandTile(size: 30)", sidebar)
        self.assertIn('SidebarRow(section: .dashboard, symbol: "square.grid.2x2")', sidebar)
        self.assertIn("Image(systemName: symbol)", sidebar)
        self.assertIn("Text(localized(section.rawValue))", sidebar)
        self.assertIn(".frame(height: 34)", sidebar)

    def test_fluid_audio_is_the_default_transcription_provider(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertIn('@Published var transcriptionProvider = "fluid"', source)
        self.assertIn('@State private var transcriptionProvider = "fluid"', recorder)

    def test_menu_bar_uses_a_compact_dedicated_overview(self):
        source = SOURCE.read_text()
        delegate = _section(source, "final class AppDelegate", "enum AppSection")
        overview = _section(source, "struct MenuBarOverview", "private struct MenuBarMeetingRow")
        launch_setup = _section(delegate, "func applicationDidFinishLaunching", "func application(_ application")

        self.assertIn("MenuBarOverview(", launch_setup)
        self.assertNotIn("RootView()", launch_setup)
        self.assertIn("NSSize(width: 320, height: 330)", launch_setup)
        self.assertIn("model.todayMeetings.prefix(model.processingSessions.isEmpty ? 3 : 2)", overview)
        self.assertIn("MenuBarProcessingRow(session: session)", overview)
        self.assertIn("BrandTile(size: 30)", overview)
        self.assertIn("RecordingControls(compact: true)", overview)
        self.assertIn('systemImage: "book.pages"', overview)
        self.assertNotIn("MenuBarMetric(title:", overview)
        self.assertNotIn('"Watcher attivo"', overview)

    def test_refresh_does_not_spawn_a_process_for_every_meeting_session(self):
        source = SOURCE.read_text()
        refresh = _section(source, "func refresh(forceProjectAccess", "func retryProjectAccess")
        retry = _section(source, "func findRetryableTranscriptionSession", "func meetingSessionDate")

        self.assertIn("let activeTranscriptionCommands = transcriptionProcessCommands()", refresh)
        self.assertEqual(retry.count('Shell.output("ps -ax -o command=")'), 0)
        self.assertIn("activeCommands: activeTranscriptionCommands", refresh)

    def test_transcription_process_scan_returns_only_relevant_commands(self):
        source = SOURCE.read_text()
        helper = _section(source, "func transcriptionProcessCommands", "func isTranscriptionProcessActive")

        self.assertIn("Shell.processCommands()", helper)
        self.assertIn('$0.contains("appletranscriber")', helper)
        self.assertIn('$0.contains("fluidaudiocli")', helper)
        self.assertIn('$0.contains("retry-transcription")', helper)

    def test_automatic_teams_metadata_capture_never_activates_teams(self):
        source = SOURCE.read_text()
        automatic_capture = _section(source, "private func startAutomaticTeamsMetadataCapture", "private func stopAutomaticTeamsMetadataCapture")
        capture = _section(source, "private func captureTeamsMetadata", "func openRecorderTarget")

        self.assertIn("captureTeamsMetadata(merge: false, openParticipants: false)", automatic_capture)
        self.assertIn("allowForegroundFallback: Bool = false", capture)
        self.assertIn("if !(ocrEnabled && allowForegroundFallback) { arguments.append(\"--no-ocr\") }", capture)

    def test_pipeline_starts_with_detection_before_recording(self):
        source = SOURCE.read_text()
        pipeline = _section(source, "struct PipelineProgress", "struct StepDot")

        self.assertIn('PipelineStep(title: "Rilevamento"', pipeline)
        self.assertLess(pipeline.index('PipelineStep(title: "Rilevamento"'), pipeline.index('PipelineStep(title: "Registrazione"'))
        self.assertIn('state: stage == 0 ? .active : .done', pipeline)
        self.assertNotIn("in corso", pipeline)
        self.assertIn(".lineLimit(1)", pipeline)

    def test_dashboard_pipeline_counts_and_meeting_tags_are_explicit(self):
        source = SOURCE.read_text()
        pipeline = _section(source, "struct PipelineProgress", "struct StepDot")
        meetings = _section(source, "struct RecentMeetingsList", "struct HistoryView")

        self.assertIn("struct PipelineStageCounts", source)
        self.assertIn("pipelineStageCounts(", source)
        self.assertIn("@Published var pipelineCounts", source)
        self.assertIn("count: model.pipelineCounts.recording", pipeline)
        self.assertIn("StepDot(state: step.state, count: step.count, number: index + 1)", pipeline)
        self.assertIn("MeetingTagBadge", meetings)
        self.assertIn("ForEach(meeting.publicationTargets.prefix(3))", meetings)

    def test_dashboard_exposes_each_active_or_failed_session_in_a_processing_queue(self):
        source = SOURCE.read_text()
        card = _section(source, "struct PipelineCard", "struct ProcessingQueueList")
        queue = _section(source, "struct ProcessingQueueList", "struct PipelineProgress")

        self.assertIn("@Published var processingSessions", source)
        self.assertIn("activeProcessingSessions(processingRoot: processingRoot, failedRoot: failedRoot)", source)
        self.assertIn("ProcessingQueueList()", card)
        self.assertIn("ForEach(model.processingSessions.prefix(3))", queue)
        self.assertIn("failureMessage", queue)
        self.assertIn("session.canRetry", queue)
        self.assertIn("retryProcessingSession(session)", queue)
        self.assertIn("discardProcessingSession(session)", queue)
        self.assertIn('"transcription_issue.json"', source)

    def test_unavailable_apple_intelligence_offers_system_settings_shortcut(self):
        source = SOURCE.read_text()
        summary = _section(source, "struct SummaryConfigurationForm", "struct ProviderTestStatus")

        self.assertIn("func openAppleIntelligenceSettings()", source)
        self.assertIn("com.apple.Siri-Settings.extension", source)
        self.assertIn('unavailableActionTitle: fixable ? "Apri Impostazioni" : nil', summary)
        self.assertIn("model.openAppleIntelligenceSettings()", summary)

    def test_accessibility_warning_can_refresh_after_system_settings_change(self):
        source = SOURCE.read_text()
        warning = _section(source, "struct AccessibilityWarningCard", "struct TranscriptionRetryCard")

        self.assertIn("func confirmAccessibilityPermission()", source)
        self.assertIn("func watchAccessibilityPermission()", source)
        self.assertIn('Button(localized("Ho attivato"))', warning)
        self.assertIn("model.confirmAccessibilityPermission()", warning)

    def test_summary_configuration_keeps_local_and_remote_endpoints_separate(self):
        source = SOURCE.read_text()
        form = _section(source, "struct SummaryConfigurationForm", "struct ConfigurationStatusBadge")

        self.assertIn('@Published var localProviderBaseURL', source)
        self.assertIn('@Published var remoteProviderBaseURL', source)
        self.assertIn('"LOCAL_SUMMARY_BASE_URL"', source)
        self.assertIn('"REMOTE_SUMMARY_BASE_URL"', source)
        self.assertIn("@State private var localBaseURL", form)
        self.assertIn("@State private var remoteBaseURL", form)

    def test_provider_connection_validates_the_selected_model(self):
        source = SOURCE.read_text()
        form = _section(source, "struct SummaryConfigurationForm", "struct ConfigurationStatusBadge")

        self.assertIn("func testProviderConnection(mode: String, baseURL: String, apiKey: String, model: String)", source)
        self.assertIn("private func providerModelExists", source)
        self.assertIn("modello disponibile", source)
        self.assertIn('localized("Connessione OK, ma il modello %@ non esiste"), requestedModel', source)
        self.assertIn("model: summaryModel", form)
        self.assertNotIn('Toggle("JSON mode provider"', form)

    def test_meeting_titles_are_normalized_for_display_without_changing_the_source_data(self):
        source = SOURCE.read_text()
        recent_meetings = _section(source, "func loadRecentMeetings", "func meetingPublicationTargets")
        processing = _section(source, "private func processingSessionTitle", "func newestDirectory")

        self.assertIn("func meetingDisplayTitle", source)
        self.assertIn('" | "', source)
        self.assertIn("emailPattern", source)
        self.assertIn("datePattern", source)
        self.assertIn("title: meetingDisplayTitle(title)", recent_meetings)
        self.assertIn("return meetingDisplayTitle(normalized)", processing)

    def test_transcription_retry_does_not_repeat_known_invalid_audio_failure(self):
        source = SOURCE.read_text()
        retry = _section(source, "func retryFailedTranscription()", "func openAppleDictationSettings()")

        self.assertIn("func unrecoverableTranscriptionIssue", source)
        self.assertIn("unrecoverableTranscriptionIssue(for: sessionURL)", retry)
        self.assertIn('presentErrorAlert("Audio non trascrivibile"', retry)

    def test_meeting_rows_label_metadata_categories_and_support_multiple_themes(self):
        source = SOURCE.read_text()
        meetings = _section(source, "struct RecentMeetingsList", "struct MeetingTagBadge")
        assigner = _section(source, "func assignTheme", "private func assignTag(")

        self.assertIn('systemImage: "folder"', meetings)
        self.assertIn("ForEach(meeting.themes.prefix(2)", meetings)
        self.assertIn('Image(systemName: "plus")', meetings)
        self.assertIn("existingValues: meeting.themes", assigner)
        self.assertIn('case "multi_select":', source)
        self.assertIn('names.map { ["name": $0] }', source)

    def test_menu_bar_reuses_the_swiftui_main_window(self):
        source = SOURCE.read_text()
        app_delegate = _section(source, "final class AppDelegate", "enum AppSection")

        main_window = _section(app_delegate, "private func showMainWindow()", "private func existingMainWindow")
        self.assertIn("existingMainWindow()", main_window)
        self.assertNotIn("let window = NSWindow(", main_window)

    def test_notion_renaming_resets_stale_destination_ids(self):
        source = SOURCE.read_text()
        save_settings = _section(source, "func saveSettings(token: String, parentPageId: String, pageName: String)", "func provisionWorkspace")
        provisioner = _section(source, "enum NativeNotionProvisioner", "struct NotionProvisionError")

        self.assertIn("let destinationChanged", save_settings)
        self.assertIn("resetDestinationForWorkspaceSwitch()", save_settings)
        self.assertNotIn("configuredDatabaseID", provisioner)

    def test_swift_env_writer_removes_duplicate_destination_keys(self):
        source = SOURCE.read_text()
        writer = _section(source, "static func update(at url", "private static func format(")

        self.assertIn("seenKeys", writer)
        self.assertIn("remaining.removeValue(forKey: key)", writer)

    def test_unreadable_recording_does_not_offer_a_misleading_transcription_retry(self):
        source = SOURCE.read_text()
        card = _section(source, "struct TranscriptionRetryCard", "struct SummaryRetryCard")

        self.assertIn("model.transcriptionAudioUnreadable", card)
        self.assertIn("Il file audio è incompleto o non leggibile", card)
        self.assertIn("if !model.transcriptionAudioUnreadable", card)

    def test_chat_uses_popover_filters_labeled_sources_and_html_answers(self):
        source = SOURCE.read_text()
        chat = _section(source, "struct ChatView", "struct ChatQuickPromptButton")

        self.assertIn("@State private var projects: Set<String> = []", chat)
        self.assertIn("@State private var themes: Set<String> = []", chat)
        self.assertIn('title: "Progetti",', chat)
        self.assertIn('title: "Temi",', chat)
        self.assertIn('prominent: true', chat)
        self.assertIn('icon: "folder.fill"', chat)
        self.assertIn('icon: "tag.fill"', chat)
        self.assertIn('ChatSourceIconToggle(source: "notion"', chat)
        self.assertIn('ChatSourceIconToggle(source: "obsidian"', chat)
        self.assertIn('ChatSourceIconToggle(source: "apple_notes"', chat)
        self.assertIn("ChatHTMLAnswer(", chat)
        self.assertIn("openCitation: openChatCitation", chat)
        self.assertIn("markdownAnswerHTML", source)
        self.assertIn("chatAnswerSections", source)
        self.assertIn("struct ChatAnswerSection", source)
        self.assertIn("model.chatProjects", chat)
        self.assertIn('DisclosureGroup("Fonti esterne")', chat)
        self.assertIn('if externalSources.contains("mongodb")', chat)
        self.assertIn("@State private var showFilters = false", chat)
        self.assertIn("private var chatFilterBar", chat)
        self.assertIn(".popover(isPresented: $showFilters", chat)
        self.assertNotIn("if showFilters", chat)
        self.assertIn('@State private var dateFilter = "all"', chat)
        self.assertIn('@State private var sources: Set<String> = ["journal", "notion", "obsidian", "apple_notes"]', chat)
        self.assertIn("private var appliedFilterCount: Int", chat)
        self.assertIn("count: appliedFilterCount", chat)
        self.assertIn('.frame(width: 620, height: 520)', chat)
        self.assertIn('if dateFilter == "custom"', chat)
        self.assertIn('Button("Applica")', chat)
        self.assertIn("Fai una domanda alle tue riunioni", chat)

    def test_chat_citation_badges_open_the_numbered_source_with_its_icon(self):
        source = SOURCE.read_text()

        self.assertIn("struct ChatCitationLinks", source)
        self.assertIn("ChatCitationSourceIcon(destination: citation.destination)", source)
        self.assertIn("Button { openCitation(citation) }", source)
        self.assertIn("private func citationSourceNumbers(in text: String) -> [Int]", source)

    def test_chat_project_and_theme_menus_support_search_and_visible_import_feedback(self):
        source = SOURCE.read_text()
        menu = _section(source, "struct ChatMultiSelectMenu", "struct ChatAnswerSection")

        self.assertIn('@State private var searchQuery = ""', menu)
        self.assertIn('TextField(localized("Cerca"), text: $searchQuery)', menu)
        self.assertIn("private var matchingValues: [String]", menu)
        self.assertIn("matchRank", menu)
        self.assertNotIn("Importa dalle fonti", menu)
        self.assertNotIn("importCatalogFromSources", menu)

    def test_chat_has_a_dedicated_auto_sync_source_menu_next_to_projects(self):
        source = SOURCE.read_text()
        chat = _section(source, "struct ChatView", "struct ChatSourceIconToggle")
        menu = _section(source, "struct ChatCatalogSourcesMenu", "struct ChatMultiSelectMenu")

        self.assertIn('@State private var catalogSources: Set<String>', chat)
        self.assertIn("ChatCatalogSourcesMenu(selection: $catalogSources, status: catalogSourceStatus)", chat)
        self.assertIn(".onChange(of: catalogSources)", chat)
        self.assertIn("syncCatalogSources()", chat)
        self.assertIn('source: "notion"', menu)
        self.assertIn('source: "obsidian"', menu)
        self.assertIn("ChatSourceIconToggle", menu)

    def test_notion_tag_assignment_adapts_to_select_and_multi_select_properties(self):
        source = SOURCE.read_text()
        assigner = _section(source, "enum NotionProjectAssigner", "struct NotionProjectError")

        self.assertIn('let propertyType = propertySchema?["type"] as? String', assigner)
        self.assertIn('case "multi_select":', assigner)
        self.assertIn('propertyValue = ["multi_select": names.map { ["name": $0] }]', assigner)
        self.assertIn('case "select", nil:', assigner)

    def test_manual_tags_update_the_local_catalog_before_optional_notion_sync(self):
        source = SOURCE.read_text()
        assignment = _section(source, "private func assignTag(", "private func showError")
        filter_refresh = _section(source, "func refreshChatFilterValues", "func indexMongoDBKnowledgeBase")

        self.assertIn("saveLocalMeetingTag(", assignment)
        self.assertIn("addConfirmedTagToCatalog(", assignment)
        self.assertIn('publicationTargets.contains("notion")', assignment)
        self.assertIn('"tag-catalog-add", "--kind", kind', assignment)
        self.assertIn("tag-catalog-migrate", filter_refresh)
        self.assertIn("La selezione sincronizza automaticamente il catalogo.", source)
        self.assertIn("tag-catalog-import-sources", source)
        self.assertIn('String(format: localized("Aggiungi %@"), localized(title).lowercased())', source)

    def test_publication_page_shows_every_destination_and_shared_page_sections(self):
        source = SOURCE.read_text()
        sidebar = _section(source, "struct Sidebar", "private struct SidebarStatusFooter")
        targets = _section(source, "struct PublicationTargetsView", "struct JournalNoteReader")

        # Destinations live in one "Connettori" page, not one sidebar entry each.
        self.assertIn("SidebarRow(section: .publicationTargets", sidebar)
        for section in (".notion", ".obsidian", ".appleNotes", ".provider"):
            self.assertNotIn(f"SidebarRow(section: {section}", sidebar)
        self.assertIn('ContentPane(title: "Connettori"', targets)
        for asset in ("Notion_app_logo.png", "2023_Obsidian_logo.svg", "apple_notes_logo.png"):
            self.assertIn(asset, targets)
        self.assertIn('detail: "Condivise da tutte le destinazioni."', targets)
        self.assertEqual(source.count("PageSectionsCard()"), 1)

    def test_publication_destination_cards_keep_configuration_in_the_main_page(self):
        source = SOURCE.read_text()
        targets = _section(source, "struct PublicationTargetsView", "struct JournalNoteReader")

        self.assertIn("struct PublicationDestinationCard", source)
        self.assertIn("NotionConfigurationForm()", targets)
        self.assertIn("ObsidianConfigurationForm()", targets)
        self.assertIn("AppleNotesConfigurationForm()", targets)

    def test_recorder_mode_cards_omit_the_intro_and_use_a_compact_shape(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")
        cards = _section(source, "struct RecorderChoiceCard", "struct RecorderModeOption")

        self.assertNotIn("Meeting Pilot userà questa modalità", recorder)
        self.assertIn("minHeight: 112", cards)
        self.assertIn("RoundedRectangle(cornerRadius: 8)", cards)

    def test_recorder_actions_are_icon_only_and_explanations_are_hidden(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertNotIn("Il banner interno di Meeting Pilot", recorder)
        self.assertNotIn("RecorderModeHelp(mode: mode)", recorder)
        self.assertNotIn('Button("Prova banner")', recorder)
        self.assertNotIn('Button("Salva dettagli recorder")', recorder)
        self.assertNotIn('Image(systemName: "play.fill")', recorder)

    def test_macos_recorder_keeps_the_teams_banner_enabled_after_legacy_setting_removal(self):
        source = SOURCE.read_text()
        refresh = _section(source, "func refresh(forceProjectAccess", "func retryProjectAccess")
        recorder_save = _section(source, "func saveRecorderSettings", "func saveRecorderFolder")

        self.assertIn('recordingPromptEnabled = configuredRecorderMode == "macos_prompt"', refresh)
        self.assertIn('"RECORDING_PROMPT_ENABLED": (mode == "macos_prompt" || promptEnabled) ? "true" : "false"', recorder_save)

    def test_recording_modes_do_not_show_descriptions(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        for description in (
            "Audio Teams + microfono in un solo file",
            "Usa l’app e la sua cartella audio",
            "Scegli un recorder installato sul Mac",
            "Puoi scegliere qualsiasi app di registrazione",
            "Con Avvia, Meeting Pilot apre TranscribeX",
        ):
            self.assertNotIn(description, recorder)

    def test_audio_folder_is_in_settings_not_in_the_recorder(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")
        settings = _section(source, "struct SettingsOverviewView", "struct LaunchAtLoginCard")

        self.assertIn('Text("Cartella audio")', settings)
        self.assertIn("model.saveRecorderFolder(audioFolder)", settings)
        self.assertNotIn('Text("Cartella audio")', recorder)

    def test_recorder_banner_saves_automatically_and_starts_from_the_right(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertNotIn('Image(systemName: "square.and.arrow.down")', recorder)
        self.assertNotIn("Mostra banner per iniziare la registrazione", recorder)
        self.assertNotIn(".onChange(of: promptEnabled)", recorder)
        self.assertNotIn(".onChange(of: promptDelay)", recorder)
        self.assertNotIn('Text("Ritardo")', recorder)
        self.assertNotIn('Image(systemName: "play.fill")', recorder)

    def test_recording_prompt_is_compact_and_uses_the_brand_tile(self):
        source = SOURCE.read_text()
        prompt_window = _section(source, "final class RecordingPromptWindow", "enum NotificationBridge")
        prompt = _section(source, "struct RecordingPromptView", "final class PermissionsSetupWindow")

        self.assertIn("NSSize(width: 440, height: 82)", prompt_window)
        self.assertIn("BrandTile(size: 40)", prompt)
        self.assertIn(".frame(width: 440, height: 82)", prompt)
        self.assertNotIn('Image(systemName: "waveform")', prompt)

    def test_obsidian_vault_is_chosen_inside_the_obsidian_card(self):
        source = SOURCE.read_text()
        obsidian = _section(source, "struct ObsidianConfigurationForm", "struct ObsidianView")
        settings = _section(source, "struct SettingsOverviewView", "struct LaunchAtLoginCard")

        self.assertNotIn('Text("Scegli vault")', obsidian)
        self.assertIn('Label("Scegli vault", systemImage: "folder.badge.plus")', obsidian)
        self.assertNotIn("Vault Obsidian", settings)

    def test_settings_overview_links_to_unified_destinations_and_uses_connection_badges(self):
        source = SOURCE.read_text()
        overview = _section(source, "struct SettingsOverviewView", "struct LaunchAtLoginCard")

        self.assertIn('Text("Destinazioni")', overview)
        self.assertIn("model.selectedSection = .journal", overview)
        self.assertIn("SettingsConnectionStatusRow", overview)
        self.assertIn('status: model.notion.occurrencesDatabaseId.isEmpty ? "Non collegato" : "Collegato"', overview)
        self.assertIn('status: model.obsidianVaultPath.isEmpty ? "Non collegato" : "Collegato"', overview)
        self.assertNotIn("PublicationTargetChip(", overview)

    def test_launch_at_login_setting_is_in_general_settings(self):
        source = SOURCE.read_text()
        overview = _section(source, "struct SettingsOverviewView", "struct LaunchAtLoginCard")

        self.assertIn("LaunchAtLoginCard()", overview)
        self.assertIn("struct LaunchAtLoginCard", source)

    def test_obsidian_actions_are_icon_only_without_global_status(self):
        source = SOURCE.read_text()
        obsidian = _section(source, "struct ObsidianConfigurationForm", "struct ObsidianView")

        for label in ("Apri vault", "Apri Obsidian", "Salva Obsidian"):
            self.assertNotIn(f'Button("{label}")', obsidian)
        self.assertNotIn("Text(model.statusMessage)", obsidian)
        for symbol in ("folder", "arrow.up.forward.app", "square.and.arrow.down"):
            self.assertIn(f'Image(systemName: "{symbol}")', obsidian)

    def test_transcription_ui_only_offers_apple_and_bundled_fluid_audio(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertIn('title: "Apple On‑Device"', recorder)
        self.assertIn('title: "FluidAudio"', recorder)
        self.assertNotIn('title: "Millet / Whisper"', recorder)
        self.assertIn('subtitle: "Riconosce chi parla."', recorder)

    def test_transcribex_download_uses_the_optional_component_panel(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertIn('URL(string: "https://www.transcribex.io/")', recorder)
        self.assertIn('if mode == "transcribex"', recorder)
        self.assertIn('Text("App di terze parti, non necessaria")', recorder)
        self.assertIn('Image(systemName: "arrow.down.circle.fill")', recorder)
        self.assertIn('.help("Scarica TranscribeX")', recorder)

    def test_summary_provider_status_is_not_shared_with_recorder_status(self):
        source = SOURCE.read_text()
        provider = _section(source, "struct SummaryConfigurationForm", "struct ProviderChoiceCard")

        self.assertIn("@Published var providerStatusMessage", source)
        self.assertIn("model.providerStatusMessage", provider)
        self.assertNotIn("ConfigurationStatusBadge(message: model.statusMessage)", provider)

    def test_tahoe_transcriber_keeps_all_incremental_results(self):
        transcriber = APPLE_TRANSCRIBER.read_text()

        self.assertIn("mergeTranscript", transcriber)
        self.assertIn("transcript = mergeTranscript(transcript, with: text)", transcriber)
        self.assertNotIn("transcript = text\n            }", transcriber)

    def test_diagnostics_reads_the_watcher_error_log(self):
        source = SOURCE.read_text()
        diagnostics = _section(source, "func diagnosticLogText", "func recentLogEntries")

        self.assertIn('"meeting-pilot.err.log"', diagnostics)

    def test_system_audio_does_not_require_screen_capture_on_tahoe(self):
        source = SOURCE.read_text()
        recorder = _section(source, "final class NativeAudioRecorder", "final class SystemMeetingAudioRecorder")
        permissions_helper = _section(source, "func permissions(", "func appleDictationEnabled")

        self.assertNotIn("CGPreflightScreenCaptureAccess()", recorder)
        self.assertNotIn("CGRequestScreenCaptureAccess()", recorder)
        self.assertIn("granted: SystemAudioPermissionState.confirmed", permissions_helper)

    def test_watcher_preserves_an_installed_fluid_audio_provider(self):
        source = SOURCE.read_text()
        app_model = source[source.index("final class AppModel"):]
        watcher = _section(app_model, "func startWatcher()", "func stopWatcher()")

        self.assertIn('case "fluid":', watcher)
        self.assertIn("fluidAudioCommandAvailable(in: env)", watcher)

    def test_sidebar_uses_system_icons_and_communications_has_teams_slack_tabs(self):
        source = SOURCE.read_text()
        sidebar = _section(source, "struct Sidebar", "private struct SidebarStatusFooter")
        communications = _section(source, "struct TeamsConfigurationSection", "struct PermissionsView")

        self.assertEqual(sidebar.count("BundledAssetIcon"), 0)
        self.assertIn("Image(systemName: symbol)", sidebar)
        self.assertIn('case slack = "Slack"', source)
        self.assertIn("CommunicationNavigation", communications)
        self.assertIn("destination == .teams", source)

    def test_communication_tabs_use_their_bundled_assets(self):
        source = SOURCE.read_text()
        navigation = _section(source, "struct CommunicationNavigation", "struct TeamsScraperView")

        self.assertIn("var assetName: String", source)
        self.assertIn('"microsoft_teams_logo.png"', source)
        self.assertIn('"Slack-Logo.webp"', source)
        self.assertIn("BundledAssetIcon(name: destination.assetName", navigation)

    def test_communication_keeps_debug_tools_collapsed_and_explains_pending_participants(self):
        source = SOURCE.read_text()
        communications = _section(source, "struct TeamsConfigurationSection", "struct PermissionsView")

        self.assertIn('@State private var showAdvancedTools = false', communications)
        self.assertIn('DisclosureGroup("Strumenti avanzati", isExpanded: $showAdvancedTools)', communications)
        self.assertIn('"I partecipanti compariranno qui quando Teams li rende disponibili."', communications)
        advanced = communications[communications.index('DisclosureGroup("Strumenti avanzati"'):]
        self.assertIn('Button("Ispeziona Teams")', advanced)
        self.assertIn("detectionDebug", advanced)
        self.assertIn("model.inspectTeamsAccessibility", advanced)

    def test_dashboard_header_holds_stats_and_recording_controls(self):
        source = SOURCE.read_text()
        dashboard = _section(source, "struct DashboardView", "struct StatTile")
        controls = _section(source, "struct RecordingControls", "\n}\n")

        self.assertIn('MPPageHeader(title: "Panoramica"', dashboard)
        self.assertIn("RecordingControls()", dashboard)
        self.assertIn('StatTile(title: "Riunioni oggi"', dashboard)
        self.assertIn('StatTile(title: "In coda"', dashboard)
        self.assertNotIn("MetricGrid()", dashboard)
        self.assertIn('systemImage: "record.circle"', controls)
        self.assertIn('model.recording.nativeRecordingPaused ? "play.fill" : "pause.fill"', controls)
        self.assertIn('"stop.fill"', controls)

    def test_native_recording_status_is_shown_in_dashboard_above_today_meetings(self):
        source = SOURCE.read_text()
        dashboard = _section(source, "struct DashboardView", "struct AccessibilityWarningCard")
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertIn("NativeRecordingStatusCard()", dashboard)
        self.assertLess(dashboard.index("NativeRecordingStatusCard()"), dashboard.index('RecentMeetingsList(title: "Riunioni di oggi"'))
        self.assertNotIn('Text("Registrazione nativa in corso")', recorder)

    def test_app_refuses_to_quit_while_native_recording_is_active(self):
        source = SOURCE.read_text()
        delegate = _section(source, "final class AppDelegate", "enum AppSection")

        self.assertIn("func applicationShouldTerminate", delegate)
        self.assertIn("model.recording.nativeRecordingActive", delegate)
        self.assertIn(".terminateCancel", delegate)
        self.assertIn("Ferma la registrazione prima di uscire", delegate)

    def test_apple_transcription_uses_speech_analyzer_on_tahoe_with_legacy_fallback(self):
        source = SOURCE.read_text()
        transcriber = APPLE_TRANSCRIBER.read_text()
        permissions_helper = _section(source, "func permissions(", "func requestAccessibilityPermission")

        self.assertIn("#available(macOS 26.0, *)", transcriber)
        self.assertIn("SpeechAnalyzer(", transcriber)
        self.assertIn("SpeechTranscriber(locale: locale, preset: .transcription)", transcriber)
        self.assertIn("AssetInventory.assetInstallationRequest", transcriber)
        self.assertIn("recognizeWithLegacySpeech", transcriber)
        self.assertIn("usesSpeechAnalyzer", source)
        self.assertIn("appleSpeechRecognitionAuthorized()", permissions_helper)
        self.assertIn('id: "apple_speech"', permissions_helper)
        self.assertIn("modernAppleSpeech", permissions_helper)
        self.assertIn("Trascrizione Apple on-device", permissions_helper)

    def test_notion_destination_name_and_space_can_be_changed(self):
        source = SOURCE.read_text()
        notion_view = _section(source, "struct NotionConfigurationForm", "struct NotionView")

        self.assertIn('"NOTION_PAGE_NAME"', source)
        self.assertIn('EditableField(label: "Nome pagina"', notion_view)
        self.assertIn("pageName = model.notion.pageName", notion_view)
        space_row = notion_view.index('SettingsRow(label: "Spazio"')
        change_space = notion_view.index("model.notion.startOAuth()", space_row)
        page_name = notion_view.index('EditableField(label: "Nome pagina"')
        self.assertLess(space_row, change_space)
        self.assertLess(change_space, page_name)
        self.assertNotIn(
            'Image(systemName: "arrow.triangle.2.circlepath")',
            notion_view[:space_row],
        )

    def test_notion_destination_actions_are_icon_only(self):
        source = SOURCE.read_text()
        notion_view = _section(source, "struct NotionConfigurationForm", "struct NotionView")

        self.assertNotIn('Button("Cambia spazio")', notion_view)
        self.assertNotIn('Button("Salva nome")', notion_view)
        for symbol, label in (
            ("arrow.triangle.2.circlepath", "Cambia spazio"),
            ("checkmark", "Salva nome"),
        ):
            self.assertIn(f'Image(systemName: "{symbol}")', notion_view)
            self.assertIn(f'.help("{label}")', notion_view)
            self.assertIn(f'.accessibilityLabel("{label}")', notion_view)

    def test_successful_notion_oauth_resets_stale_destination_before_provisioning(self):
        source = SOURCE.read_text()
        callback = _section(source, "func handleOAuthCallback", "func chooseParentPage")
        reset = _section(source, "private func resetDestinationForWorkspaceSwitch", "\n    }\n")

        self.assertIn("resetDestinationForWorkspaceSwitch()", callback)
        self.assertLess(
            callback.index("resetDestinationForWorkspaceSwitch()"),
            callback.index("provisionWorkspace("),
        )
        for key in (
            "NOTION_APP_PAGE_ID",
            "NOTION_SERIES_DATABASE_ID",
            "NOTION_OCCURRENCES_DATABASE_ID",
            "NOTION_DATABASE_ID",
        ):
            self.assertIn(f'"{key}": ""', reset)
        for property_name in ("appPageId", "seriesDatabaseId", "occurrencesDatabaseId"):
            self.assertIn(f'{property_name} = ""', reset)

    def test_automatic_stop_uses_a_shared_fifteen_second_delay(self):
        source = SOURCE.read_text()
        external_stop = _section(source, "private func monitorExternalRecordingState", "private func beginOrCompleteAutomaticStop")
        native_stop = _section(source, "private func beginOrCompleteAutomaticStop", "private func isWatcherRunning")

        self.assertIn("private let automaticStopConfirmationSeconds = 15", source)
        self.assertIn("automaticStopConfirmationSeconds", external_stop)
        self.assertIn("automaticStopConfirmationSeconds", native_stop)
        self.assertNotIn("25 secondi", native_stop)

    def test_processing_session_with_publication_targets_is_still_transcribing(self):
        self.assertNotIn(
            '($0.hasSuffix(".json") && !$0.contains("metadata"))',
            SOURCE.read_text(),
        )

    def test_processing_session_is_considered_for_transcription_recovery(self):
        source = SOURCE.read_text()
        self.assertIn("in: processingRoot,", source)
        self.assertIn("activeCommands: activeTranscriptionCommands", source)

    def test_active_transcription_process_excludes_processing_session_recovery(self):
        source = SOURCE.read_text()
        helper = _section(source, "func isTranscriptionProcessActive", "func findRetryableTranscriptionSession")

        self.assertIn('func isTranscriptionProcessActive(for session: URL, activeCommands:', helper)
        self.assertIn('"appletranscriber"', helper)
        self.assertIn('"fluidaudiocli"', helper)
        self.assertIn('"retry-transcription"', helper)
        self.assertIn("session.path", helper)
        self.assertIn("audioPaths", helper)
        self.assertIn("!isTranscriptionProcessActive(for: session, activeCommands: activeCommands)", source)

    def test_recording_prompt_is_only_shown_for_a_new_meeting(self):
        source = SOURCE.read_text()
        helper = _section(source, "func pollMeeting()", "private func")

        self.assertIn("private var meetingWasDetected = false", source)
        self.assertIn("let appInputActive = platform.processIsRunningInput() == true", helper)
        self.assertIn("let activeMeeting = title != nil && appInputActive", helper)
        self.assertIn("let meetingJustStarted = activeMeeting && !meetingWasDetected", helper)
        self.assertIn("meetingWasDetected = activeMeeting", helper)
        self.assertIn("guard let title, activeMeeting else", helper)
        self.assertNotIn("title != lastPromptTitle", helper)
        self.assertNotIn("Date().timeIntervalSince(lastPromptDate)", helper)

    def test_fluid_audio_is_a_bundled_transcription_provider(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertIn('title: "FluidAudio"', recorder)
        self.assertIn('selectTranscriptionProvider("fluid")', recorder)
        self.assertNotIn('model.installFluidAudioRuntime()', recorder)
        self.assertIn('prepareBundledFluidAudio()', source)
        self.assertIn('appendingPathComponent("FluidAudio/bin/fluidaudiocli")', source)
        self.assertIn('["parakeet-tdt-0.6b-v3", "speaker-diarization"]', source)

    def test_journal_publication_switch_is_visible_with_other_destinations(self):
        source = SOURCE.read_text()
        targets = _section(source, "struct PublicationTargetsView", "struct JournalNoteReader")

        cards = targets[:targets.index('MPSectionTitle("Sezioni pagina"')]
        self.assertIn('target: "journal"', cards)
        self.assertIn('title: "Diario locale"', cards)

    def test_chat_section_has_sidebar_route_filters_and_cli_command(self):
        source = SOURCE.read_text()
        sidebar = _section(source, "struct Sidebar", "struct ServiceNavigation")

        self.assertIn('case chat = "Chat"', source)
        self.assertIn("ChatView()", source)
        self.assertIn("SidebarRow(section: .chat, symbol:", sidebar)
        self.assertIn("struct ChatView", source)
        chat_view = _section(source, "struct ChatView", "struct JournalView")

        for label in ('title: "Progetti",', 'title: "Temi",', 'ChatFilterField(label: "Da")', 'ChatFilterField(label: "A")'):
            self.assertIn(label, chat_view)
        for source_toggle in ('ChatSourceIconToggle(source: "journal"', 'ChatSourceIconToggle(source: "notion"', 'ChatSourceIconToggle(source: "obsidian"', 'ChatSourceIconToggle(source: "apple_notes"'):
            self.assertIn(source_toggle, chat_view)
        self.assertIn("model.askMeetingChat(", chat_view)
        self.assertIn('var arguments = ["chat", "--question", trimmedQuestion', source)
        self.assertIn('arguments += ["--source", source]', source)

    def test_chat_phase_two_has_quick_prompts_and_explicit_save_actions(self):
        source = SOURCE.read_text()
        chat_view = _section(source, "struct ChatView", "struct ChatSourceIconToggle")

        for prompt in (
            "Decisioni",
            "Azioni aperte",
            "Rischi e blocchi",
            "Evoluzione tema",
            "Ultima settimana",
        ):
            self.assertIn(prompt, chat_view)
        self.assertIn("setQuickPrompt(", chat_view)
        self.assertIn('ChatSaveButton("Diario"', chat_view)
        self.assertIn("saveMeetingChat(destination: \"journal\"", chat_view)
        self.assertIn("saveMeetingChat(destination: \"notion\"", chat_view)
        self.assertIn("saveMeetingChat(destination: \"obsidian\"", chat_view)
        self.assertIn('["chat-save", "--payload-stdin"]', source)
        self.assertNotIn("salvataggio automatico", chat_view.lower())

    def test_chat_phase_three_has_external_sources_scope_and_mongodb_indexing(self):
        source = SOURCE.read_text()
        chat_view = _section(source, "struct ChatView", "struct ChatSourceIconToggle")

        self.assertIn('DisclosureGroup("Fonti esterne")', chat_view)
        self.assertIn('ChatChoiceChip("Meeting", isSelected: searchScope == "meetings")', chat_view)
        self.assertIn('ChatChoiceChip("Knowledge base", isSelected: searchScope == "knowledge")', chat_view)
        self.assertIn('ChatChoiceChip("Entrambe", isSelected: searchScope == "both")', chat_view)
        for label in ('ChatSourceIconToggle(source: "notion", sources: $externalSources, knowledgeBase: true)', 'ChatSourceIconToggle(source: "obsidian", sources: $externalSources, knowledgeBase: true)', 'ChatSourceIconToggle(source: "mongodb", sources: $externalSources, knowledgeBase: true)'):
            self.assertIn(label, chat_view)
        self.assertIn('ChatFilterField(label: "URI MongoDB")', chat_view)
        self.assertIn('ChatFilterField(label: "Database")', chat_view)
        self.assertIn('ChatFilterField(label: "Collection")', chat_view)
        self.assertIn("model.indexMongoDBKnowledgeBase(", chat_view)
        self.assertIn("kb-index-mongodb", source)
        self.assertIn("--external-source", source)

    def test_chat_phase_four_uses_existing_provider_and_keeps_secrets_out_of_arguments(self):
        source = SOURCE.read_text()
        chat_view = _section(source, "struct ChatView", "struct ChatSourceIconToggle")
        indexer = _section(source, "func indexMongoDBKnowledgeBase", "func saveMeetingChat")

        self.assertNotIn("SUMMARY_API_KEY", chat_view)
        self.assertNotIn("providerAPIKey", chat_view)
        self.assertIn("--uri-stdin", indexer)
        self.assertIn("standardInput:", indexer)
        self.assertNotIn("--uri \\(shellQuote(trimmedURI))", indexer)
        self.assertIn("--payload-stdin", source)

    def test_cloud_provider_is_picked_from_chips_with_optional_endpoint(self):
        source = SOURCE.read_text()
        cloud = _section(source, "private var cloudSettingsRows", "private func scheduleAutomaticProviderSave")

        self.assertIn("CloudProviderChip(option: option, selected: remoteProviderKind == option.kind)", cloud)
        self.assertIn('TextField(remoteEndpointPlaceholder(for: remoteProviderKind), text: $baseURL)', cloud)
        self.assertIn('if remoteProviderKind == "other"', cloud)
        self.assertNotIn('Text("Provider cloud")', cloud)

    def test_provider_switch_keeps_a_selected_model_and_chat_answer_scrolls(self):
        source = SOURCE.read_text()
        provider = _section(source, "struct SummaryConfigurationForm", "private func inferredRemoteProviderKind")
        chat = _section(source, "struct ChatView", "struct ChatQuickPromptButton")

        defaults = _section(provider, "private func applyRemoteProviderDefaults", "private func selectProviderMode")
        self.assertIn('summaryModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty', defaults)
        self.assertNotIn('force || summaryModel', defaults)
        self.assertIn("private var chatContent", chat)
        self.assertIn(".frame(maxWidth: .infinity, maxHeight: .infinity", chat)
        self.assertIn("private var conversation: some View", chat)
        self.assertIn("ScrollView {", chat)

    def test_pipeline_combines_recording_transcription_and_summary_configuration(self):
        source = SOURCE.read_text()
        recorder = _section(source, "struct RecorderView", "struct RecorderChoiceCard")

        self.assertIn('ContentPane(title: "Pipeline"', recorder)
        self.assertIn('Text("Registrazione")', recorder)
        self.assertIn('Text("Trascrizione")', recorder)
        self.assertIn('Text("Sintesi (AI)")', recorder)
        self.assertIn("SummaryConfigurationForm()", recorder)
        self.assertIn("SummaryContentSection()", recorder)

    def test_summary_prompt_lives_in_the_summary_content_section(self):
        source = SOURCE.read_text()
        form = _section(source, "struct SummaryConfigurationForm", "struct ProviderTestStatus")
        content = _section(source, "struct SummaryContentSection", "struct SummaryTemplateEditor")

        self.assertNotIn("Prompt personalizzato", form)
        self.assertIn('title: "Prompt personalizzato"', content)
        self.assertIn("saveSummaryPrompt(", content)

    def test_root_layout_keeps_sidebar_visible_when_content_resizes(self):
        source = SOURCE.read_text()
        root = _section(source, "struct RootView", "struct Sidebar")
        sidebar = _section(source, "struct Sidebar", "struct ServiceNavigation")

        self.assertIn("Sidebar()\n                .layoutPriority(1)", root)
        self.assertIn(".frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)", root)
        self.assertIn(".clipped()", root)
        self.assertIn(".fixedSize(horizontal: true, vertical: false)", sidebar)


if __name__ == "__main__":
    unittest.main()
