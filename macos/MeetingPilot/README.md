# Meeting Pilot macOS

Interfaccia macOS nativa per controllare la pipeline `meeting-pilot`.
E' una menu bar app: resta nella barra in alto di macOS, non nel Dock.

## Build locale

```bash
cd /path/to/meeting-pilot
chmod +x macos/MeetingPilot/Scripts/*.sh
macos/MeetingPilot/Scripts/build_app.sh
open "macos/MeetingPilot/build-current/Meeting Pilot.app"
```

Uso:

- click sinistro sull'icona: apre la dashboard.
- click destro sull'icona: menu rapido con avvio/pausa watcher ed uscita.
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

Il DMG creato cosi contiene una app firmata ad-hoc e preserva i permessi di
esecuzione. Su altri Mac restera' l'avviso Gatekeeper per sviluppatore non
verificato, ma l'utente dovrebbe poter usare il flusso standard da Impostazioni
di Sistema > Privacy e sicurezza > Apri comunque, senza Terminal. Per eliminare
anche quell'avviso servono firma Developer ID, hardened runtime e notarizzazione
Apple.

## Come trova il progetto

La app usa questo ordine:

1. variabile ambiente `MEETING_PILOT_PROJECT_ROOT` (solo build debug)
2. file bundle `Resources/default-project-root.txt`
3. percorso corrente del progetto usato in fase di build

La prima versione e' pensata come wrapper non sandboxed: deve poter avviare il watcher, leggere log, leggere `.env`, aprire Notion e lanciare lo scraper Teams.
