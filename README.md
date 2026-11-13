# ARNOVIDEO

App per iPhone e iPad: carichi uno o più video (MP4/MOV) e foto, li metti in sequenza
su una timeline (le foto con durata regolabile) ed esporti un unico video MP4.

| Cartella | Contenuto |
|---|---|
| `Web/` | La pagina ARNOVIDEO (tutta l'app sta qui; funziona anche in Safari) |
| `iOS/` | Il "contenitore" dell'app iPhone/iPad, come per ARNOCLICK |
| `project.yml` | Descrizione del progetto Xcode (generato da XcodeGen) |
| `.github/workflows/ios.yml` | Compila l'app su un Mac di GitHub e la manda su TestFlight |

## Come si compila
1. Su GitHub: **Actions → App iPhone e iPad → Run workflow**.
2. "Verifica" controlla che l'app si compili (non serve l'account Apple).
3. "TestFlight" firma e carica l'app, se nei *Secrets* del repository ci sono
   `APPLE_TEAM_ID`, `APP_BUNDLE_ID` (it.arnone.arnovideo), `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`
   (gli stessi usati per ARNOCLICK, tranne il Bundle ID).

© 2026 Maurizio Arnone. Tutti i diritti riservati.
