#!/bin/bash
# ARNOVIDEO (Chrome): apre la pagina di ARNOVIDEO in una finestra di Google Chrome senza barra degli indirizzi.
URL="https://maarnone52-oss.github.io/Arnovideo/"
if open -Ra "Google Chrome" >/dev/null 2>&1; then
  open -na "Google Chrome" --args --app="$URL" --window-size=1180,860
else
  osascript -e 'display dialog "ARNOVIDEO ha bisogno di Google Chrome.\n\nOra si apre la pagina per scaricarlo: installalo, poi riapri ARNOVIDEO." buttons {"OK"} default button 1 with title "ARNOVIDEO" with icon caution' >/dev/null 2>&1
  open "https://www.google.com/chrome/"
fi
