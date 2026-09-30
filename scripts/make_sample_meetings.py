#!/usr/bin/env python3
"""Create fake meeting sessions to demo publishing to Notion/Obsidian.

Each session holds a silent WAV (retry-summary requires an audio file), a
speaker-labelled transcript, and calendar-like metadata, so it can be fed to:

    transcribe-to-notion retry-summary --session-dir <session>
"""
from __future__ import annotations

import argparse
import json
import wave
from datetime import datetime, timedelta
from pathlib import Path

SAMPLES = [
    {
        "slug": "sprint-review",
        "title": "Sprint Review – App Mobile",
        "project": "App Mobile",
        "theme": "Sviluppo",
        "minutes": 35,
        "participants": ["Giulia Rossi", "Marco Bianchi", "Sara Conti", "Luca Ferri"],
        "lines": [
            ("Giulia Rossi", "Buongiorno a tutti, iniziamo con la sprint review. Obiettivo dello sprint era chiudere il nuovo onboarding e il login con Apple."),
            ("Marco Bianchi", "L'onboarding è in produzione da martedì. Il login con Apple è completo lato app, ma il backend deve ancora validare il token in modo corretto, quindi è dietro feature flag."),
            ("Sara Conti", "Dai dati di analytics il completamento dell'onboarding è passato dal 58 al 71 percento nei primi tre giorni. È un buon segnale ma il campione è piccolo."),
            ("Luca Ferri", "Sul backend la validazione del token Apple la chiudo entro giovedì. Il rischio è la rotazione delle chiavi pubbliche, voglio aggiungere una cache con scadenza."),
            ("Giulia Rossi", "Ok. Decidiamo allora che il login con Apple va in rilascio con la versione 2.4, non prima. Marco, riesci a preparare la build per TestFlight venerdì?"),
            ("Marco Bianchi", "Sì, venerdì mattina. Mi servono però i testi definitivi per la schermata di consenso."),
            ("Sara Conti", "Te li mando io entro mercoledì, li sto rivedendo con il legale."),
            ("Giulia Rossi", "Punto aperto: il crash su Android 12 nella fotocamera. Qualcuno l'ha riprodotto?"),
            ("Luca Ferri", "Non ancora, succede solo su alcuni Samsung. Propongo di aprire un ticket e chiedere i log a due utenti beta."),
            ("Giulia Rossi", "D'accordo. Chiudiamo qui, ci rivediamo alla planning di lunedì."),
        ],
    },
    {
        "slug": "cliente-kickoff",
        "title": "Kickoff progetto con Acme Retail",
        "project": "Acme Retail",
        "theme": "Clienti",
        "minutes": 50,
        "participants": ["Paolo Greco", "Elena Marino", "Andrea Colombo (Acme)", "Francesca Ricci (Acme)"],
        "lines": [
            ("Paolo Greco", "Grazie per essere qui. Oggi allineiamo obiettivi, tempi e referenti per il nuovo portale fornitori."),
            ("Andrea Colombo (Acme)", "Per noi la priorità è ridurre le email con i fornitori. Oggi gestiamo circa 400 ordini a settimana a mano."),
            ("Elena Marino", "Proponiamo una prima release in otto settimane con caricamento ordini, stato spedizioni e notifiche. La fatturazione la mettiamo nella seconda fase."),
            ("Francesca Ricci (Acme)", "Otto settimane vanno bene, ma a fine novembre abbiamo il picco del Black Friday, non possiamo andare live in quel periodo."),
            ("Paolo Greco", "Allora fissiamo il go-live al 12 gennaio, con un pilota su cinque fornitori a metà dicembre."),
            ("Andrea Colombo (Acme)", "Per me va bene. L'integrazione con il nostro ERP chi la segue?"),
            ("Elena Marino", "La seguiamo noi, ma ci serve l'accesso all'ambiente di test dell'ERP e la documentazione delle API entro due settimane."),
            ("Francesca Ricci (Acme)", "Mi prendo io l'azione, vi mando accessi e documentazione entro il 14 ottobre."),
            ("Paolo Greco", "Resta aperta la questione del single sign-on: usate Azure AD anche per i fornitori esterni?"),
            ("Andrea Colombo (Acme)", "Non lo so, devo verificarlo con l'IT. Vi rispondo la prossima settimana."),
            ("Paolo Greco", "Perfetto. Faremo un punto settimanale ogni martedì alle 10."),
        ],
    },
    {
        "slug": "one-to-one",
        "title": "1:1 Paolo / Sara",
        "project": "Team",
        "theme": "Persone",
        "minutes": 25,
        "participants": ["Paolo Greco", "Sara Conti"],
        "lines": [
            ("Paolo Greco", "Come stai? Come sono andate queste due settimane?"),
            ("Sara Conti", "Bene, ma un po' piena. Tra analytics dell'app e il report per Acme ho avuto poco tempo per il corso di SQL avanzato."),
            ("Paolo Greco", "Capito. Il report per Acme possiamo spostarlo a Elena per questo mese, così liberi mezza giornata a settimana per la formazione."),
            ("Sara Conti", "Sarebbe perfetto. Vorrei anche presentare i risultati dell'onboarding all'all-hands di fine mese."),
            ("Paolo Greco", "Ottima idea. Prepara cinque slide, le rivediamo insieme il 24."),
            ("Sara Conti", "Un'ultima cosa: si parlava di un budget per le conferenze. È ancora disponibile?"),
            ("Paolo Greco", "Credo di sì, lo verifico con HR e ti faccio sapere entro venerdì."),
        ],
    },
    {
        "slug": "incident-postmortem",
        "title": "Post-mortem incidente pagamenti 18/09",
        "project": "Piattaforma",
        "theme": "Operations",
        "minutes": 40,
        "participants": ["Luca Ferri", "Davide Esposito", "Giulia Rossi", "Marco Bianchi"],
        "lines": [
            ("Davide Esposito", "Ricapitolo: il 18 settembre dalle 14:05 alle 14:52 circa il 30 percento dei pagamenti con carta è fallito."),
            ("Luca Ferri", "La causa è stata la scadenza del certificato mTLS verso il gateway di pagamento. Il rinnovo automatico era configurato ma puntava al vecchio secret."),
            ("Giulia Rossi", "Perché non ce ne siamo accorti prima? Avevamo un alert sulla scadenza?"),
            ("Davide Esposito", "L'alert c'era ma mandava email a una lista che non esiste più. Nessuno l'ha ricevuto."),
            ("Marco Bianchi", "Lato app gli utenti hanno visto un errore generico. Dovremmo mostrare un messaggio più chiaro e proporre di riprovare."),
            ("Giulia Rossi", "Decisioni: spostiamo tutti gli alert di scadenza certificati su PagerDuty e facciamo un audit di tutti i secret entro fine mese."),
            ("Luca Ferri", "L'audit lo faccio io, entro il 30 settembre."),
            ("Davide Esposito", "Io aggiorno il runbook e configuro PagerDuty entro lunedì."),
            ("Marco Bianchi", "Io preparo il nuovo messaggio di errore per il prossimo rilascio."),
            ("Giulia Rossi", "Rischio residuo: altri servizi potrebbero avere lo stesso problema di secret. Finché l'audit non è chiuso teniamo monitoraggio manuale giornaliero."),
        ],
    },
    {
        "slug": "marketing-q4",
        "title": "Pianificazione campagna marketing Q4",
        "project": "Marketing",
        "theme": "Strategia",
        "minutes": 45,
        "participants": ["Chiara Lombardi", "Elena Marino", "Paolo Greco"],
        "lines": [
            ("Chiara Lombardi", "Per il Q4 propongo di concentrare il budget su due canali: LinkedIn per il B2B e una newsletter mensile."),
            ("Paolo Greco", "Quanto budget pensi per LinkedIn?"),
            ("Chiara Lombardi", "Circa 12 mila euro sul trimestre, con tre campagne da quattro settimane ciascuna."),
            ("Elena Marino", "Possiamo usare il caso Acme come case study? Sarebbe molto convincente."),
            ("Paolo Greco", "Solo dopo il go-live e con la loro approvazione scritta. Per ora usiamo i numeri dell'app mobile."),
            ("Chiara Lombardi", "Ok. Decidiamo quindi LinkedIn più newsletter, e rimandiamo il webinar a gennaio."),
            ("Elena Marino", "Scrivo io la prima newsletter, esce il 15 ottobre."),
            ("Chiara Lombardi", "Io preparo il piano editoriale e le creatività entro il 10 ottobre."),
            ("Paolo Greco", "Domanda aperta: misuriamo i lead con HubSpot o restiamo sul foglio condiviso? Decidiamolo la prossima settimana."),
        ],
    },
]


def write_silent_wav(path: Path, seconds: float = 1.0, rate: int = 16000) -> None:
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(b"\x00\x00" * int(seconds * rate))


def create_session(root: Path, sample: dict, start: datetime) -> Path:
    session = root / f"{start:%Y-%m-%d_%H%M}_{sample['slug']}"
    session.mkdir(parents=True, exist_ok=True)
    end = start + timedelta(minutes=sample["minutes"])

    write_silent_wav(session / "recording.wav")
    transcript = "\n".join(f"{speaker}: {text}" for speaker, text in sample["lines"])
    (session / "transcript.txt").write_text(transcript + "\n", encoding="utf-8")
    fluid = {
        "text": transcript,
        "speakers": [{"id": name, "label": name} for name in dict.fromkeys(s for s, _ in sample["lines"])],
        "segments": [{"speaker": speaker, "text": text} for speaker, text in sample["lines"]],
    }
    (session / "fluidaudio_transcript.json").write_text(
        json.dumps(fluid, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    frontmatter = {
        "title": sample["title"],
        "date": start.isoformat(),
        "duration": sample["minutes"] * 60,
        "language": "it",
        "participants": sample["participants"],
        "project": sample["project"],
        "theme": sample["theme"],
    }
    (session / "meeting.frontmatter.json").write_text(
        json.dumps(frontmatter, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )

    metadata = {
        "match_found": True,
        "title": sample["title"],
        "start": start.isoformat(),
        "end": end.isoformat(),
        "calendar": "Esempio",
        "participants": sample["participants"],
        "project": sample["project"],
        "theme": sample["theme"],
    }
    (session / "meeting_metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return session


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-n", "--count", type=int, default=len(SAMPLES))
    parser.add_argument("--root", type=Path, default=Path("~/TeamsMeetings/samples").expanduser())
    args = parser.parse_args()

    base = datetime.now().replace(hour=10, minute=0, second=0, microsecond=0).astimezone()
    for index in range(args.count):
        sample = SAMPLES[index % len(SAMPLES)]
        start = base - timedelta(days=index + 1)
        print(create_session(args.root, sample, start))


if __name__ == "__main__":
    main()
