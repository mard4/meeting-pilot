# Meeting Pilot macOS

Interfaccia macOS nativa per controllare la pipeline `meeting-pilot`.
E' una menu bar app: resta nella barra in alto di macOS, non nel Dock.

Community: [Discord di Meeting Pilot](https://discord.gg/3Atx7yvFk).

## Build locale

```bash
cd /path/to/meeting-pilot
chmod +x macos/MeetingPilot/Scripts/*.sh
macos/MeetingPilot/Scripts/build_app.sh
open "macos/MeetingPilot/build-current/Meeting Pilot.app"
```

Uso:

- click sinistro sull'icona: apre la dashboard.
- click destro sull'icona: menu rapido con avvio/pausa watcher, link al Discord ed uscita.
- sezione Recorder: scegli TranscribeX, recorder macOS prompt o cartella custom.
- sezione Recorder: abilita il banner "Vuoi iniziare la registrazione?", scegli ritardo e target da aprire con Avvia.
- sezione Notion: scegli o cambia lo spazio parent, configura il nome pagina e riusa oppure crea una sola tabella per le riunioni.
- sezione Provider sintesi: scegli Locale o Provider API, testa la connessione e scegli quali sezioni includere nelle pagine Notion.
- sezione Permessi: ogni riga ha un pulsante Abilita che apre il pannello macOS corretto; al primo avvio appare una checklist dei permessi mancanti.

## DMG locale

```bash
macos/MeetingPilot/Scripts/make_dmg.sh
open macos/MeetingPilot/build-current
```

Se nel portachiavi c'e' un certificato "Developer ID Application", gli script lo
usano da soli: l'app ha l'hardened runtime e, con `NOTARY_KEYCHAIN_PROFILE`, il DMG
viene notarizzato e si apre senza avvisi Gatekeeper (vedi DISTRIBUZIONE.md). Senza
Developer ID il DMG contiene una app firmata ad-hoc: su altri Mac serve Impostazioni
di Sistema > Privacy e sicurezza > Apri comunque.

## Come trova il progetto

La app usa questo ordine:

1. variabile ambiente `MEETING_PILOT_PROJECT_ROOT` (solo build debug)
2. file bundle `Resources/default-project-root.txt`
3. percorso corrente del progetto usato in fase di build

La prima versione e' pensata come wrapper non sandboxed: deve poter avviare il watcher, leggere log, leggere `.env`, aprire Notion e lanciare lo scraper Teams.
