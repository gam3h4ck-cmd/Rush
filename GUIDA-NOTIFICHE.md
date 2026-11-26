# Notifiche push · come attivarle

Servono 5 passaggi, una sola volta. Le chiavi sono nel file `segreti-notifiche.txt`
(tienilo fuori dal repository).

1. **Database** · Supabase → SQL Editor → incolla `supabase/aggiornamento-notifiche.sql` → Run.
2. **Funzione** · Supabase → Edge Functions → Deploy a new function → *Via Editor*.
   Nome: `notify`. Sostituisci tutto il codice con `supabase/functions/notify/index.ts` → Deploy.
   Poi apri la funzione → Details (o Settings) → **disattiva "Verify JWT"** → Save.
   (La verifica la fa il codice: admin collegato, link del dipendente o segreto del cron.)
3. **Segreti** · Edge Functions → Secrets: aggiungi VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY,
   VAPID_SUBJECT, CRON_SECRET (parte A del file segreti).
4. **Promemoria** · SQL Editor → incolla la parte B del file segreti → Run.
   Ogni ora il database chiama la funzione; alle 18:00 (Impostazioni → "Promemoria del turno")
   avvisa chi lavora il giorno dopo.
5. **Sito** · GitHub Desktop → Commit → Push. Cloudflare pubblica da solo.

## Cosa ricevono i dipendenti
- Planning pubblicato o modificato: quando premi **Avvisa il team** nel Planning
  (il numero indica quante persone hanno turni nuovi o cambiati, da questa settimana a +8).
- Risposta a ferie / giorni liberi (anche le assenze che aggiungi tu).
- Cambi turno: richiesta ricevuta, risposta del collega, decisione finale.
- Promemoria la sera prima del turno.

Ognuno le attiva dal proprio link (pagina Turni → "Attiva notifiche").
Su iPhone (iOS 16.4+) prima bisogna aggiungere la pagina alla schermata Home e aprirla da lì.

## Se qualcosa non va
- Supabase → Edge Functions → notify → Logs.
- "Invio non riuscito" nell'admin: la funzione non è pubblicata o "Verify JWT" è ancora attivo.
- Errore `rpc ... 401` nei log: aggiungi il segreto `RUSH_SERVICE_KEY` con la chiave
  *secret* del progetto (Project Settings → API Keys).
