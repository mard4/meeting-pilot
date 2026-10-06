from __future__ import annotations

import dataclasses
import json
import re
import sqlite3
import ssl
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

import certifi

from ..config import Config
from ..language import NOT_FOUND_ANSWERS, config_language, label, language_name
from ..slides.deck import TEXT_NAME, slides_dir, slides_from_texts
from ..summarization.omlx_client import is_ollama, ollama_chat_request, strip_model_wrapping, summary_endpoint
from .knowledge_base import default_knowledge_index_path, load_knowledge_documents
from ..tag_catalog import catalog_values


ChatProvider = Callable[[str, str], str]

QUICK_PROMPTS = {
    "it": {
        "project_decisions": "Quali decisioni sono state prese per il progetto {project}?",
        "open_actions": "Quali sono le azioni aperte e i responsabili per il progetto {project}?",
        "risks_blocks": "Quali rischi e blocchi emergono per il progetto {project}?",
        "theme_evolution": "Come si è evoluto il tema {theme} nei meeting selezionati?",
        "last_week_changes": "Cosa è cambiato dall'ultima settimana per il progetto {project}?",
    },
    "en": {
        "project_decisions": "Which decisions were made for the {project} project?",
        "open_actions": "What are the open actions and their owners for the {project} project?",
        "risks_blocks": "Which risks and blockers are emerging for the {project} project?",
        "theme_evolution": "How has the {theme} topic evolved across the selected meetings?",
        "last_week_changes": "What changed since last week for the {project} project?",
    },
}


@dataclass(frozen=True)
class MeetingChatFilters:
    project: str | None = None
    theme: str | None = None
    projects: tuple[str, ...] = ()
    themes: tuple[str, ...] = ()
    start_date: str | None = None
    end_date: str | None = None
    sources: tuple[str, ...] = ()
    search_scope: str = "meetings"
    external_sources: tuple[str, ...] = ()


@dataclass(frozen=True)
class MeetingChatCitation:
    title: str
    date: str | None
    destination: str
    url: str


@dataclass(frozen=True)
class MeetingChatResult:
    answer: str
    citations: list[MeetingChatCitation] = field(default_factory=list)


@dataclass(frozen=True)
class _MeetingDocument:
    session_id: str
    title: str
    date: str | None
    project: str
    theme: str
    destination: str
    url: str
    text: str
    session_path: str


@dataclass(frozen=True)
class _Passage:
    document: _MeetingDocument
    text: str
    score: int


def answer_meeting_question(
    config: Config,
    question: str,
    filters: MeetingChatFilters | None = None,
    provider: ChatProvider | None = None,
) -> MeetingChatResult:
    filters = filters or MeetingChatFilters()
    passages = search_meeting_passages(config, question, filters)
    not_found = label(config_language(config), "chat_not_found")
    if not passages:
        return MeetingChatResult(answer=not_found)

    citations = _citations_for(passages)
    citation_numbers = {
        (citation.title, citation.url): index
        for index, citation in enumerate(citations, start=1)
    }
    system_prompt = _chat_system_prompt(config_language(config))
    user_prompt = json.dumps(
        {
            "question": question,
            "filters": {
                "projects": list(_filter_values(filters.projects, filters.project)),
                "themes": list(_filter_values(filters.themes, filters.theme)),
                "start_date": filters.start_date,
                "end_date": filters.end_date,
                "sources": list(filters.sources),
                "search_scope": filters.search_scope,
                "external_sources": list(filters.external_sources),
            },
            "sources": [
                {
                    # The model cites the source number, not the transient
                    # passage number. Several passages can belong to one
                    # meeting/document, while the UI exposes one clickable
                    # citation per unique source.
                    "id": citation_numbers[(passage.document.title, passage.document.url)],
                    "meeting": passage.document.title,
                    "date": passage.document.date,
                    "destination": passage.document.destination,
                    "url": passage.document.url,
                    "passage": passage.text,
                }
                for index, passage in enumerate(passages, start=1)
            ],
        },
        ensure_ascii=False,
    )
    answer = (provider or _openai_compatible_chat(config))(system_prompt, user_prompt).strip()
    if not answer:
        answer = not_found
    if answer not in NOT_FOUND_ANSWERS and citations and not re.search(r"\[\d+\]", answer):
        return MeetingChatResult(answer=not_found)
    return MeetingChatResult(answer=answer, citations=citations)


def _chat_system_prompt(language: str) -> str:
    def h(key: str) -> str:
        return label(language, key)

    return (
        f"You are Meeting Intelligence. Answer in {language_name(language)}, using only the supplied passages. "
        "Aim for complete, verifiable coverage of the question: do not leave out facts, decisions, actions, "
        "exceptions, blockers, deadlines, owners or uncertainties that appear in the relevant passages, even when "
        "there are many. Do not repeat the same point: group equivalent items while keeping every distinguishing "
        "detail. Return only semantic HTML, no Markdown and no code blocks, with exactly this structure: "
        f"<section><h3>{h('chat_summary')}</h3><p>...</p><h3>{h('chat_facts')}</h3><ul><li>...</li></ul>"
        f"<h3>{h('chat_decisions')}</h3><ul><li>...</li></ul><h3>{h('chat_inferences')}</h3><ul><li>...</li></ul></section>. "
        f"The {h('chat_summary')} section is the direct answer to the question in two to four concise sentences and "
        "carries one or more [number] citations. Every item in the following sections must be self-contained, "
        "concrete and carry a [number] citation for the source that supports it. If a section has nothing, use a "
        f"single <li>{h('chat_empty_section')}</li>. Inferences must be explicitly marked as such and never presented "
        "as facts. If the passages are not enough to answer, return only: "
        f"{h('chat_not_found')}"
    )


def quick_prompt_question(
    prompt_id: str,
    project: str | None = None,
    theme: str | None = None,
    language: str = "it",
) -> str:
    prompts = QUICK_PROMPTS["it" if language == "it" else "en"]
    template = prompts.get(prompt_id)
    if not template:
        raise ValueError(f"Unknown quick prompt: {prompt_id}")
    fallback = label(language, "selected")
    values = {
        "project": (project or fallback).strip() or fallback,
        "theme": (theme or fallback).strip() or fallback,
    }
    return template.format(**values)


def available_chat_projects(config: Config, external_sources: tuple[str, ...] = ()) -> list[str]:
    return available_chat_filter_values(config, external_sources)["projects"]


def available_chat_filter_values(config: Config, external_sources: tuple[str, ...] = ()) -> dict[str, list[str]]:
    # Filters are a curated local taxonomy. Historical transcripts and external
    # knowledge can be searched, but must not silently grow the menu.
    values = catalog_values(config)
    return {"projects": values["projects"], "themes": values["topics"]}


def save_meeting_chat_result(
    config: Config,
    answer: str,
    citations: list[MeetingChatCitation],
    destination: str,
    question: str,
) -> dict[str, Any]:
    if not citations:
        raise ValueError("Le citazioni sono obbligatorie per salvare una risposta chat.")
    normalized = destination.strip().lower().replace("-", "_")
    title = _chat_result_title(question)
    markdown = _chat_result_markdown(title, question, answer, citations, config_language(config))
    if normalized == "journal":
        root = config.journal_root.expanduser()
        path = _unique_markdown_path(root / "Chat" / _month_folder(), title)
        path.write_text(markdown, encoding="utf-8")
        return {"provider": "journal", "title": title, "path": str(path)}
    if normalized == "obsidian":
        vault = getattr(config, "obsidian_vault_path", None)
        if not vault:
            raise ValueError("Obsidian non configurato.")
        folder = str(getattr(config, "obsidian_folder", "Meeting Pilot") or "Meeting Pilot").strip("/")
        path = _unique_markdown_path(vault.expanduser() / folder / "Chat", title)
        path.write_text(markdown, encoding="utf-8")
        return {"provider": "obsidian", "title": title, "path": str(path)}
    if normalized == "notion":
        return _save_chat_result_to_notion(config, title, markdown)
    raise ValueError(f"Destinazione chat non supportata: {destination}")


def search_meeting_passages(
    config: Config,
    question: str,
    filters: MeetingChatFilters | None = None,
    limit: int = 6,
) -> list[_Passage]:
    filters = filters or MeetingChatFilters()
    query_terms = _terms(question)
    documents = _documents_for_scope(config, filters)
    passages: list[_Passage] = []
    filtered_documents: list[_MeetingDocument] = []
    for document in documents:
        if not _matches_filters(document, filters):
            continue
        filtered_documents.append(document)
        for chunk in _chunks(document.text):
            score = _score(chunk, query_terms, document, filters)
            if score > 0:
                passages.append(_Passage(document=document, text=chunk, score=score))

    # A selected project or topic is itself a strong search constraint. Generic
    # questions such as "what was decided?" often share no literal words with a
    # transcript, so retain a small context from matching meetings instead of
    # incorrectly reporting that no meeting was found.
    if not passages and _has_taxonomy_filter(filters):
        for document in filtered_documents:
            for chunk in list(_chunks(document.text))[:2]:
                passages.append(_Passage(document=document, text=chunk, score=1))
    passages.sort(key=lambda passage: (passage.score, passage.document.date or ""), reverse=True)
    return passages[:limit]


def _documents_for_scope(config: Config, filters: MeetingChatFilters) -> list[_MeetingDocument]:
    scope = filters.search_scope.strip().lower()
    documents: list[_MeetingDocument] = []
    if scope in {"meetings", "both", ""}:
        documents.extend(_meeting_documents(config))
    if scope in {"knowledge", "kb", "both"}:
        if not filters.external_sources:
            return documents
        documents.extend(_knowledge_documents(config, filters.external_sources))
    return documents


def _meeting_documents(config: Config) -> list[_MeetingDocument]:
    done_dir = config.done_dir.expanduser()
    documents = [
        _with_slides(document, done_dir / document.session_id)
        for document in _documents_from_journal_index(config.journal_root.expanduser() / "index.sqlite")
    ]
    by_key = {_document_key(document): document for document in documents}
    for document in _documents_from_done_dir(config.done_dir.expanduser()):
        by_key.setdefault(_document_key(document), document)
    return list(by_key.values())


def _documents_from_journal_index(index_path: Path) -> list[_MeetingDocument]:
    if not index_path.exists():
        return []
    try:
        with sqlite3.connect(index_path) as database:
            database.row_factory = sqlite3.Row
            columns = {row[1] for row in database.execute("PRAGMA table_info(entries)")}
            optional = {
                name: name if name in columns else "'' AS " + name
                for name in ("project", "theme", "destination", "session_path")
            }
            rows = database.execute(
                f"""SELECT session_id, title, meeting_date, summary, path,
                          {optional['project']}, {optional['theme']},
                          {optional['destination']}, {optional['session_path']}
                   FROM entries"""
            ).fetchall()
    except sqlite3.Error:
        return []
    documents = []
    for row in rows:
        path = str(row["path"] or "")
        text = _read_text(Path(path)) or str(row["summary"] or "")
        documents.append(
            _MeetingDocument(
                session_id=str(row["session_id"] or path),
                title=str(row["title"] or "Meeting"),
                date=str(row["meeting_date"] or "") or None,
                project=str(row["project"] or ""),
                theme=str(row["theme"] or ""),
                destination=str(row["destination"] or "Diario"),
                url=Path(path).as_uri() if path else "",
                text=text,
                session_path=str(row["session_path"] or ""),
            )
        )
    return documents


def _documents_from_done_dir(done_dir: Path) -> list[_MeetingDocument]:
    if not done_dir.exists():
        return []
    documents = []
    for session in sorted((path for path in done_dir.iterdir() if path.is_dir()), reverse=True):
        metadata = _read_json(session / "meeting_metadata.json")
        summary = _read_json(session / "omlx_summary.json")
        project_metadata = _read_json(session / "meeting_project.json")
        theme_metadata = _read_json(session / "meeting_theme.json")
        title = str(summary.get("title") or metadata.get("title") or session.name)
        date = str(metadata.get("start") or metadata.get("recording_start") or summary.get("date") or "") or None
        project = str(project_metadata.get("project") or metadata.get("project") or summary.get("tag") or "")
        theme = str(theme_metadata.get("theme") or metadata.get("theme") or summary.get("theme") or "")
        text = "\n".join(
            part for part in (str(summary.get("summary") or ""), _read_transcript(session), _slides_text(session)) if part
        )
        for destination, url in _destinations_for_session(session):
            documents.append(
                _MeetingDocument(
                    session_id=session.name,
                    title=title,
                    date=date,
                    project=project,
                    theme=theme,
                    destination=destination,
                    url=url,
                    text=text,
                    session_path=str(session),
                )
            )
    return documents


def _knowledge_documents(config: Config, sources: tuple[str, ...]) -> list[_MeetingDocument]:
    configured = getattr(config, "knowledge_index_path", None)
    index_path = configured.expanduser() if configured else default_knowledge_index_path(config.journal_root)
    documents = []
    for document in load_knowledge_documents(index_path, sources):
        metadata = document.metadata or {}
        documents.append(
            _MeetingDocument(
                session_id=document.external_id,
                title=document.title,
                date=document.updated_at,
                project=", ".join(sorted(_project_values_from_metadata(metadata), key=str.casefold)),
                theme=", ".join(sorted(_theme_values_from_metadata(metadata), key=str.casefold)),
                destination=_knowledge_destination(document.source),
                url=document.url,
                text=document.text,
                session_path=f"kb:{document.source}:{document.external_id}",
            )
        )
    return documents


def _project_values_from_metadata(metadata: dict[str, Any]) -> set[str]:
    return _metadata_values(metadata, ("project", "project_name", "progetto", "projects"))


def _theme_values_from_metadata(metadata: dict[str, Any]) -> set[str]:
    return _metadata_values(metadata, ("theme", "tema", "topic", "topics", "themes"))


def _metadata_values(metadata: dict[str, Any], keys: tuple[str, ...]) -> set[str]:
    values: set[str] = set()
    for key in keys:
        value = metadata.get(key)
        if isinstance(value, str) and value.strip():
            values.add(value.strip())
        elif isinstance(value, (list, tuple, set)):
            values.update(str(item).strip() for item in value if str(item).strip())
    return values


def _destinations_for_session(session: Path) -> list[tuple[str, str]]:
    destinations: list[tuple[str, str]] = []
    journal = _read_json(session / "journal_receipt.json")
    if journal.get("path"):
        destinations.append(("Diario", Path(str(journal["path"])).as_uri()))
    notion = _read_json(session / "notion_receipt.json")
    if notion.get("url"):
        destinations.append(("Notion", str(notion["url"])))
    obsidian = _read_json(session / "obsidian_receipt.json")
    if obsidian.get("path"):
        destinations.append(("Obsidian", Path(str(obsidian["path"])).as_uri()))
    if (session / "apple_notes_receipt.json").exists():
        destinations.append(("Apple Notes", "notes://"))
    if not destinations:
        destinations.append(("Sessione completata", session.as_uri()))
    return destinations


def _matches_filters(document: _MeetingDocument, filters: MeetingChatFilters) -> bool:
    projects = _filter_values(filters.projects, filters.project)
    themes = _filter_values(filters.themes, filters.theme)
    if projects and not _matches_any_value(document.project, projects):
        return False
    if themes and not _matches_any_value(document.theme, themes):
        return False
    if filters.sources:
        allowed = {_source_label(source) for source in filters.sources}
        if _source_label(document.destination) not in allowed:
            return False
    document_date = _parse_date(document.date)
    if filters.start_date and document_date:
        start = _parse_date(filters.start_date)
        if start and document_date < start:
            return False
    if filters.end_date and document_date:
        end = _parse_date(filters.end_date)
        if end and document_date > end:
            return False
    return True


def _filter_values(values: tuple[str, ...], legacy_value: str | None) -> tuple[str, ...]:
    selected = [value.strip() for value in values if value.strip()]
    if legacy_value and legacy_value.strip():
        selected.append(legacy_value.strip())
    return tuple(dict.fromkeys(selected))


def _has_taxonomy_filter(filters: MeetingChatFilters) -> bool:
    return bool(_filter_values(filters.projects, filters.project) or _filter_values(filters.themes, filters.theme))


def _matches_any_value(document_value: str, selected_values: tuple[str, ...]) -> bool:
    normalized_document = _normalize(document_value)
    return any(_normalize(value) in normalized_document for value in selected_values)


def _knowledge_destination(source: str) -> str:
    labels = {
        "mongodb": "MongoDB",
        "notion": "Notion KB",
        "obsidian": "Obsidian KB",
        "google_drive": "Google Drive",
        "sharepoint": "SharePoint",
    }
    return labels.get(source, source.replace("_", " ").title())


def _chunks(text: str) -> Iterable[str]:
    normalized = re.sub(r"\s+", " ", text).strip()
    if not normalized:
        return []
    parts = re.split(r"(?<=[.!?])\s+|\n+", normalized)
    chunks = [part.strip() for part in parts if part.strip()]
    if len(chunks) == 1 and len(chunks[0]) > 900:
        return [chunks[0][index : index + 900] for index in range(0, len(chunks[0]), 900)]
    return chunks


def _score(chunk: str, query_terms: set[str], document: _MeetingDocument, filters: MeetingChatFilters) -> int:
    haystack = _normalize(chunk)
    score = sum(2 for term in query_terms if term in haystack)
    for marker in ("decisione", "deciso", "azione", "rischio", "blocco", "tema"):
        if marker in haystack and marker in query_terms:
            score += 3
    if any(_normalize(project) in haystack for project in _filter_values(filters.projects, filters.project)):
        score += 4
    if any(_normalize(theme) in haystack for theme in _filter_values(filters.themes, filters.theme)):
        score += 3
    return score


def _citations_for(passages: list[_Passage]) -> list[MeetingChatCitation]:
    citations: list[MeetingChatCitation] = []
    seen: set[tuple[str, str]] = set()
    for passage in passages:
        key = (passage.document.title, passage.document.url)
        if key in seen:
            continue
        seen.add(key)
        citations.append(
            MeetingChatCitation(
                title=passage.document.title,
                date=passage.document.date,
                destination=passage.document.destination,
                url=passage.document.url,
            )
        )
    return citations


def _openai_compatible_chat(config: Config) -> ChatProvider:
    def provider(system_prompt: str, user_prompt: str) -> str:
        payload: dict[str, Any] = {
            "model": config.summary_model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.0,
        }
        headers = {"Content-Type": "application/json"}
        if config.summary_api_key:
            headers["Authorization"] = f"Bearer {config.summary_api_key}"
        with summary_endpoint(config) as base_url:
            ollama = is_ollama(config)
            if ollama:
                url, body = ollama_chat_request(config, payload["messages"], temperature=0.0, json_output=False)
            else:
                url, body = f"{base_url}/chat/completions", payload
            request = urllib.request.Request(
                url,
                data=json.dumps(body).encode("utf-8"),
                headers=headers,
                method="POST",
            )
            ssl_context = ssl.create_default_context(cafile=certifi.where())
            try:
                with urllib.request.urlopen(request, timeout=120, context=ssl_context) as response:
                    data = json.loads(response.read().decode("utf-8"))
            except urllib.error.URLError as exc:
                raise RuntimeError(f"Meeting chat provider request failed: {exc}") from exc
        content = data["message"]["content"] if ollama else data["choices"][0]["message"]["content"]
        return strip_model_wrapping(str(content))

    return provider


def result_to_dict(result: MeetingChatResult) -> dict[str, Any]:
    return {
        "answer": result.answer,
        "citations": [
            {
                "title": citation.title,
                "date": citation.date,
                "destination": citation.destination,
                "url": citation.url,
            }
            for citation in result.citations
        ],
    }


def citations_from_payload(payload: list[dict[str, Any]]) -> list[MeetingChatCitation]:
    return [
        MeetingChatCitation(
            title=str(item.get("title") or "Fonte"),
            date=str(item.get("date") or "") or None,
            destination=str(item.get("destination") or ""),
            url=str(item.get("url") or ""),
        )
        for item in payload
        if isinstance(item, dict)
    ]


def _chat_result_title(question: str) -> str:
    compact = re.sub(r"\s+", " ", question).strip(" ?!.") or "Risposta chat"
    return f"Chat - {compact[:80]}"


def _chat_result_markdown(
    title: str,
    question: str,
    answer: str,
    citations: list[MeetingChatCitation],
    language: str = "it",
) -> str:
    lines = [
        f"# {title}",
        "",
        f"{label(language, 'chat_question')}: {question}",
        f"{label(language, 'chat_saved')}: {datetime.now(timezone.utc).isoformat()}",
        "",
        f"## {label(language, 'chat_answer')}",
        answer.strip() or label(language, "chat_not_found"),
    ]
    if citations:
        lines.extend(["", f"## {label(language, 'chat_sources')}"])
        for index, citation in enumerate(citations, start=1):
            details = " · ".join(part for part in (citation.date, citation.destination) if part)
            suffix = f" ({details})" if details else ""
            lines.append(f"- [{index}] {citation.title}{suffix}: {citation.url}")
    lines.append("")
    return "\n".join(lines)


def _month_folder() -> Path:
    now = datetime.now()
    return Path(f"{now.year:04d}") / f"{now.month:02d}"


def _unique_markdown_path(folder: Path, title: str) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    stem = re.sub(r"[^A-Za-z0-9À-ÿ._ -]+", "", title).strip().replace("/", "-") or "Chat"
    path = folder / f"{stem}.md"
    counter = 2
    while path.exists():
        path = folder / f"{stem} {counter}.md"
        counter += 1
    return path


def _save_chat_result_to_notion(config: Config, title: str, markdown: str) -> dict[str, Any]:
    token = getattr(config, "notion_token", None)
    parent_id = getattr(config, "notion_app_page_id", None) or getattr(config, "notion_parent_page_id", None)
    if not token or not parent_id:
        raise ValueError("Notion non configurato.")
    try:
        from notion_client import Client
    except ImportError as exc:
        raise RuntimeError("notion-client non installato.") from exc
    client = Client(auth=token)
    page = client.pages.create(
        parent={"page_id": parent_id},
        properties={"title": {"title": [{"type": "text", "text": {"content": title[:120]}}]}},
        children=[
            {"object": "block", "type": "paragraph", "paragraph": {"rich_text": [{"type": "text", "text": {"content": chunk}}]}}
            for chunk in _notion_chunks(markdown)
        ],
    )
    return {"provider": "notion", "title": title, "url": page.get("url", ""), "id": page.get("id", "")}


def _notion_chunks(text: str) -> list[str]:
    chunks = []
    for paragraph in text.split("\n\n"):
        paragraph = paragraph.strip()
        if not paragraph:
            continue
        while paragraph:
            chunks.append(paragraph[:1900])
            paragraph = paragraph[1900:]
    return chunks[:80]


def _document_key(document: _MeetingDocument) -> tuple[str, str]:
    return (document.session_path or document.session_id, document.destination)


def _terms(value: str) -> set[str]:
    stopwords = {"cosa", "stato", "stata", "sono", "sui", "sul", "del", "della", "questo", "questa"}
    return {term for term in re.findall(r"[\wÀ-ÿ]+", _normalize(value)) if len(term) > 2 and term not in stopwords}


def _normalize(value: object) -> str:
    return str(value or "").casefold().strip()


def _source_label(value: str) -> str:
    normalized = _normalize(value).replace("_", " ").replace("-", " ")
    if normalized in {"journal", "diario"}:
        return "diario"
    if normalized == "apple notes":
        return "apple notes"
    if normalized == "sessione completata":
        return "sessione completata"
    return normalized


def _parse_date(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def _read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError:
        return ""


def _with_slides(document: _MeetingDocument, session: Path) -> _MeetingDocument:
    """A Diary page names its slides but holds only their titles; their text lives in
    the archived session."""
    slides = _slides_text(session)
    return dataclasses.replace(document, text=f"{document.text}\n{slides}") if slides else document


def _slides_text(session: Path) -> str:
    """The text of the slides shown in a meeting or lecture, so answers can draw on them."""
    payload = _read_json(slides_dir(session) / TEXT_NAME)
    pages = payload.get("pages") if isinstance(payload.get("pages"), list) else []
    slides = slides_from_texts([str(page.get("text") or "") for page in pages if isinstance(page, dict)])
    return "\n".join(f"Slide {slide.page}: {' '.join(slide.text.split())}" for slide in slides if slide.text)


def _read_transcript(session: Path) -> str:
    for path in sorted(session.glob("*.txt")):
        if path.name.endswith(".ffmpeg.log"):
            continue
        text = _read_text(path)
        if text:
            return text
    return ""
