# SidecarSwitch (app)

App macOS nativa che sposta la sessione Sidecar dell'iPad tra due Mac:

- **Lavoro**: il Mac su cui gira l'app.
- **Personale**: il Mac comandato via SSH.

L'app è un orchestratore: non usa SidecarCore in-process, ma esegue i binari
`SidecarLauncher`, `connected`, `dispid` e `arrange` come sottoprocessi, in locale o via SSH.

## Requisiti

- macOS 14.2 o successivo, **arm64** (Apple Silicon) su entrambi i Mac.
- **Mac personale**:
  - Remote Login (SSH) attivo.
  - Chiave pubblica dedicata in `~/.ssh/authorized_keys`.
  - Tool remoti compilati in `tools/bin/` (`SidecarLauncher`, `connected`, `dispid`, `arrange`) con
    `tools/build.sh`; architettura `arm64`.
  - LaunchAgent `local.sidecar.vdisp` attivo, con display virtuale `vendor 0x5644`.
  - Coperchio chiuso durante l'uso come target Sidecar.
- **Mac di lavoro**: coperchio aperto, display integrato disponibile. L'app lascia a macOS il
  layout **esteso** dell'iPad e non esegue `mirror`/`arrange` su questo lato.
- Rete: se il Mac aziendale usa un proxy locale (per esempio **SquidMan** con
  `http_proxy=http://localhost:4242` e `https_proxy=http://localhost:4242`), l'app eredita proxy e
  certificati CA dal **login shell** dell'utente. Non usa l'ambiente LaunchServices (che spesso non li
  contiene). Se il login shell non espone proxy/CA, l'app usa un'allowlist minima e lo registra nel log.

## Configurazione

Al primo avvio l'app crea:

```
~/Library/Application Support/SidecarSwitch/config.json
```

Il file usa `schemaVersion: 2` e i 5 path dei tool remoti. I default sono generici (host e path
vuoti): finché `remote.host` o uno dei path usati (`binaryPath`, `connectedPath`, `dispidPath`,
`arrangePath`) è vuoto, il lato **Personale** è disabilitato e non viene eseguito alcun comando SSH.
Il lato Lavoro resta disponibile.

Per configurare:

1. Copia `config.example.json` in
   `~/Library/Application Support/SidecarSwitch/config.json` (oppure usa **Apri config** nella
   finestra dell'app).
2. Imposta `remote.host`, `remote.user`, `identityFile` e i path dei tool sul Mac personale.
   - `identityFile` accetta un `~` iniziale, espanso localmente.
   - I path remoti devono essere **assoluti** e non accettano `~`.
3. Salva e premi **Ricarica config**: la nuova configurazione viene applicata senza riavviare l'app.

`config.json` è scritto `0600` in una directory `0700`; le riscritture usano un file temporaneo e
mantengono un backup `.bak`. Un JSON non valido viene preservato byte-per-byte e l'app resta viva con
l'ultima configurazione valida.

## Host key e `known_hosts`

L'app usa un file dedicato e **senza spazi**:

```
~/.sidecar-switch/known_hosts   (0600, directory 0700)
```

Al primo avvio, se esiste il vecchio
`~/Library/Application Support/SidecarSwitch/known_hosts`, viene copiato nel nuovo path (il vecchio
resta). La prima connessione usa `StrictHostKeyChecking=accept-new` (TOFU); il fingerprint SHA-256
viene registrato nel log. **Dimentica host key** rimuove l'entry con `ssh-keygen -R`. Un mismatch non
modifica mai il file automaticamente.

## Verifica manuale SSH (K13a/K13e)

L'argv manuale deve rispecchiare quello dell'app:

```
/usr/bin/ssh \
  -F "$HOME/.ssh/config" \
  -i "$HOME/.ssh/id_ed25519_sidecar_switch" \
  -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=15 \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$HOME/.sidecar-switch/known_hosts" \
  -T <utente>@<host> \
  '/percorso/remoto/tools/bin/SidecarLauncher connect "iPad"'
```

`-F` va incluso solo se `$HOME/.ssh/config` esiste; `-p` va incluso solo se la porta non è 22.
Ripetere la verifica dopo sleep/reboot con il tunnel (`ProxyCommand`) attivo.

## Build e verifica

```
cd app
swift test
./build.sh
./verify-bundle.sh
```

`build.sh` produce `app/build/SidecarSwitch.app` con firma ad-hoc, i 5 tool in `Contents/Resources`,
l'icona `AppIcon.icns` e la licenza. `verify-bundle.sh` ricostruisce il bundle in una directory
temporanea e verifica struttura, `Info.plist`, architettura `arm64`, icona (10 taglie e
riproducibilità SHA-256 dei pixel RGBA 1024) e firma ad-hoc.

## Licenza

MIT. Vedi `LICENSE` nella radice del repository e in `Contents/Resources/LICENSE`.
