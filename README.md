# ARNOCUT (ex ARNOVIDEO)

- **Pagina web installabile (iPhone, iPad, Mac):** https://maarnone52-oss.github.io/Arnovideo/
- **App per Mac Catalina e successivi:** pagina [Releases](https://github.com/maarnone52-oss/Arnovideo/releases) → `ArnoVideo-VERSIONE-Catalina.pkg` oppure `.dmg`
- **ARNOVIDEO Chrome per Mac, consigliata su High Sierra e Mojave:** [ArnoVideo-Chrome.pkg](https://github.com/maarnone52-oss/Arnovideo/releases/download/mac-chrome/ArnoVideo-Chrome.pkg) oppure [ArnoVideo-Chrome.dmg](https://github.com/maarnone52-oss/Arnovideo/releases/download/mac-chrome/ArnoVideo-Chrome.dmg)

App per iPhone, iPad e Mac: carichi uno o più video (MP4/MOV) e foto, li metti in sequenza
su una timeline (le foto con durata regolabile) ed esporti un unico video MP4.

| Cartella | Contenuto |
|---|---|
| `Web/` | La pagina ARNOVIDEO (tutta l'app sta qui; funziona anche in Safari) |
| `iOS/` | Il "contenitore" dell'app iPhone/iPad, come per ARNOCLICK |
| `Mac/` | Il "contenitore" dell'app per Mac (Catalina e successivi) |
| `MacChrome/` | ARNOVIDEO Chrome: apre la pagina web in una finestra di Chrome |
| `project.yml` | Descrizione del progetto Xcode (generato da XcodeGen) |
| `.github/workflows/ios.yml` | Compila l'app su un Mac di GitHub e la manda su TestFlight |

## Come si compila
1. Su GitHub: **Actions → App iPhone e iPad → Run workflow**.
2. "Verifica" controlla che l'app si compili (non serve l'account Apple).
3. "TestFlight" firma e carica l'app, se nei *Secrets* del repository ci sono
   `APPLE_TEAM_ID`, `APP_BUNDLE_ID` (it.arnone.arnovideo), `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`
   (gli stessi usati per ARNOCLICK, tranne il Bundle ID).

© 2026 Maurizio Arnone. Tutti i diritti riservati.
