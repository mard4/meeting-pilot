# Distribuzione macOS

Se macOS mostra `Meeting Pilot e' danneggiata e non puo' essere aperta`,
non e' un problema dei permessi Privacy. L'app viene bloccata da Gatekeeper
prima dell'avvio, quindi non puo' comparire nessun popup in Privacy e sicurezza.

## Regola per Codex

Quando Codex prepara o modifica una release macOS di Meeting Pilot deve sempre:

1. firmare ad-hoc l'intero bundle prima di distribuirlo, anche senza Developer
   ID;
2. verificare il bundle con `codesign --verify --deep --strict`;
3. controllare che `codesign -dv --verbose=4` mostri `Signature=adhoc`;
4. creare e distribuire un DMG, non uno zip;
5. verificare che il DMG contenga una app firmata e con permessi di esecuzione
   preservati;
6. considerare `spctl --assess --type execute -v` `rejected` come normale
   quando manca Developer ID/notarizzazione, purche' la firma sia valida.

Non consegnare mai agli utenti finali una `.app` completamente non firmata o un
archivio zip come formato principale di distribuzione.

## Build locale

La build locale usa una firma ad-hoc completa:

```bash
macos/MeetingPilot/Scripts/build_app.sh
macos/MeetingPilot/Scripts/make_dmg.sh
macos/MeetingPilot/Scripts/make_pkg.sh
```

Prima di distribuire, verifica sempre il bundle:

```bash
codesign --verify --deep --strict --verbose=4 "macos/MeetingPilot/build-current/Meeting Pilot.app"
codesign -dv --verbose=4 "macos/MeetingPilot/build-current/Meeting Pilot.app"
spctl --assess --type execute -v "macos/MeetingPilot/build-current/Meeting Pilot.app"
```

Con firma ad-hoc, `codesign` deve risultare valido e `codesign -dv` deve mostrare
`Signature=adhoc`. `spctl` dira' comunque `rejected`: e' normale senza Developer
ID e notarizzazione.

Il DMG e' una distribuzione drag-and-drop: l'utente deve copiare
`Meeting Pilot.app` in Applications. Distribuisci il DMG, non uno zip: il DMG
preserva firma e permessi di esecuzione in modo affidabile. Lo script
`make_dmg.sh` verifica la firma del bundle prima di creare l'immagine e copia la
app con `ditto`.

Aprendo il DMG compare una finestra con l'icona dell'app a sinistra, una freccia
e il collegamento ad Applications a destra. Lo sfondo e' in
`assets/dmg_background.tiff` (rigeneralo con `Scripts/dmg_background.swift` a
scala 1 e 2, poi `tiffutil -cathidpicheck`). La disposizione viene applicata da
Finder via AppleScript: la prima volta macOS chiede il permesso Automazione per
Finder al Terminale; se manca, il DMG viene creato lo stesso ma senza layout.

Il PKG installa direttamente `Meeting Pilot.app` in `/Applications`, quindi e'
utile se vuoi evitare che l'app venga avviata dal volume montato del DMG.

Il PKG mostra anche una guida durante l'installazione con:

- panoramica dell'app;
- configurazione Notion;
- scelta provider AI;
- recorder e trascrizione;
- permessi macOS;
- indicazioni per il primo avvio.

Il DMG mantiene macOS 14 come requisito minimo. Apple Intelligence viene collegata debolmente e compare come provider predefinito solo quando il framework, il dispositivo, il modello e la lingua risultano disponibili; negli altri casi l'app usa la configurazione oMLX locale.

Se il DMG viene scaricato da browser, Drive, Slack o simili, macOS applichera'
la quarantine. Con una app firmata ad-hoc, il flusso atteso su un Mac senza
Developer ID e notarizzazione e':

1. doppio click su `Meeting Pilot.app`;
2. avviso per sviluppatore non verificato;
3. Impostazioni di Sistema > Privacy e sicurezza > Apri comunque.

Questo evita il Terminal all'utente finale, ma non elimina l'avviso Gatekeeper.
Se compare solo "app danneggiata" e non compare "Apri comunque", controlla di
non aver distribuito una app non firmata, una app modificata dopo la firma o uno
zip che ha rotto permessi/firma.

Per test interni puoi ancora rimuovere la quarantine dopo aver copiato l'app in
Applications:

```bash
xattr -dr com.apple.quarantine "/Applications/Meeting Pilot.app"
open "/Applications/Meeting Pilot.app"
```

Questo resta un workaround di test, non la procedura per utenti finali.

## Distribuzione a utenti finali

Senza pagare il Developer ID puoi distribuire un DMG con app firmata ad-hoc. Gli
utenti vedranno l'avviso Gatekeeper e potranno sbloccare l'app da Privacy e
sicurezza con "Apri comunque".

Per eliminare anche l'avviso Gatekeeper e avere il flusso delle app commerciali
servono:

1. Apple Developer Program attivo.
2. Certificato `Developer ID Application`.
3. Certificato `Developer ID Installer` se distribuisci il PKG.
4. Firma con hardened runtime.
5. Notarizzazione Apple.
6. Stapling del ticket di notarizzazione sul DMG o sul PKG.

Configurazione una tantum delle credenziali di notarizzazione (password
specifica per app, salvata nel Keychain di login):

```bash
xcrun notarytool store-credentials meeting-pilot-notary \
  --apple-id "email@appleid.com" \
  --team-id "TEAMID"
```

Release DMG firmata, notarizzata e stapled in un solo passaggio:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Nome Cognome (TEAMID)"
export NOTARY_KEYCHAIN_PROFILE="meeting-pilot-notary"
macos/MeetingPilot/Scripts/build_app.sh
macos/MeetingPilot/Scripts/make_dmg.sh
```

`build_app.sh` firma ogni Mach-O (anche le `.so`/`.dylib` di PyInstaller) con
hardened runtime e applica `MeetingPilot.entitlements` (microfono, Apple
Events) all'app e `MeetingPilotCLI.entitlements` alla CLI Python. Senza questi
entitlements l'app notarizzata non riceve audio dal microfono e non puo' pilotare
Teams/Note via AppleScript, senza mostrare errori.

`make_dmg.sh` rifiuta di notarizzare un bundle firmato ad-hoc e, se
`NOTARY_KEYCHAIN_PROFILE` e' impostato, chiama `Scripts/notarize.sh`, che invia
il DMG, stampa il log Apple in caso di rifiuto, esegue `stapler staple` e
verifica con `spctl`.

Release PKG:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Nome Cognome (TEAMID)"
export PRODUCTSIGN_IDENTITY="Developer ID Installer: Nome Cognome (TEAMID)"
export NOTARY_KEYCHAIN_PROFILE="meeting-pilot-notary"
macos/MeetingPilot/Scripts/build_app.sh
macos/MeetingPilot/Scripts/make_pkg.sh
```

`Scripts/notarize.sh <file>` si puo' anche lanciare a mano su un DMG o PKG gia'
firmato.

## Bundle ID

Il bundle ID definitivo e' `io.github.mard4.MeetingPilot` (Info.plist,
`AppIdentity.bundleID` in `ConfigLocators.swift`, `Installer/Distribution.xml`;
un test verifica che coincidano). Non cambiarlo dopo il lancio: macOS lega i
permessi Privacy (microfono, audio di sistema, Accessibilita', Automazione) al
bundle ID, quindi ogni utente dovrebbe riconcederli. I segreti salvati nel
Keychain dalle build precedenti con `it.local.MeetingPilot` vengono migrati
automaticamente.

Quando il DMG e' firmato, notarizzato e stapled, macOS permette l'apertura senza
il blocco per sviluppatore non verificato e solo dopo l'app potra' chiedere
Accessibilita', Microfono, Calendario e gli altri permessi Privacy.

Quando il PKG e' firmato, notarizzato e stapled, macOS permette
l'installazione direttamente in `/Applications`.
