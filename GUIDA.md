# Rush · Guida per mettere online l'app

Tempo totale: circa 30 minuti. Non serve saper programmare.

## Cosa c'è in questa cartella

| Cartella / file | A cosa serve |
|---|---|
| `app/` | **L'app da mettere online** (e solo questa cartella) |
| `app/config.js` | **L'unico file che devi modificare**: il collegamento a Supabase |
| `app/index.html` | L'app per te (admin) |
| `app/staff.html` | La pagina che vedono i dipendenti con il loro link personale |
| `supabase/schema.sql` | Il database, da incollare una sola volta in Supabase |
| `supabase/import-dati-attuali.sql` | I tuoi 7 dipendenti e i turni della settimana 48 (**non metterlo online**: contiene le tariffe) |

---

## 1. Crea il database su Supabase

1. Vai su **supabase.com**, accedi e premi **New project**.
2. Nome: `rush`. Regione: **Central EU (Frankfurt)**. Scegli una password del database lunga e salvala in un posto sicuro (non la userai nell'app).
3. Aspetta 1–2 minuti che il progetto sia pronto.
4. Nel menu a sinistra apri **SQL Editor**, premi **New query**.
5. Apri il file `supabase/schema.sql`, copia tutto il contenuto, incollalo e premi **Run**.
   Deve comparire "Success. No rows returned".

## 2. Collega l'app al database

1. In Supabase vai su **Project Settings → API Keys** (o premi **Connect** in alto).
2. Copia il **Project URL** (tipo `https://abcdefgh.supabase.co`) e la **Publishable key** (inizia con `sb_publishable_`). Se vedi solo la chiave **anon public**, va bene lo stesso.
3. Apri `app/config.js` con un editor di testo (Blocco note / TextEdit) e sostituisci:
   - `INSERISCI_PROJECT_URL` con il Project URL
   - `INSERISCI_ANON_KEY` con la Publishable key (o anon key)
4. Salva il file.

⚠️ Non usare mai la chiave **secret** o **service_role**: dà accesso a tutto.

## 3. Metti online l'app su Cloudflare Pages

1. Vai su **dash.cloudflare.com**, accedi e apri **Workers & Pages**.
2. Premi **Create** → scheda **Pages** → **Upload assets** (caricamento diretto, senza GitHub).
3. Nome del progetto: per esempio `rush-mito`. Diventerà l'indirizzo `https://rush-mito.pages.dev`.
4. Trascina **solo la cartella `app`** e premi **Deploy**. Non caricare la cartella `supabase` né questa guida.
5. Dopo qualche secondo ti dà l'indirizzo dell'app. Copialo.

## 4. Dì a Supabase qual è l'indirizzo dell'app

Serve per le email di conferma e di recupero password.

1. In Supabase vai su **Authentication → URL Configuration**.
2. **Site URL**: incolla l'indirizzo Cloudflare (es. `https://rush-mito.pages.dev`).
3. In **Redirect URLs** aggiungi lo stesso indirizzo e salva.

## 5. Crea il tuo account admin

1. Apri l'indirizzo dell'app, scrivi la tua email e una password (almeno 8 caratteri) e premi **Crea account**.
2. Apri l'email di conferma di Supabase e clicca il link.
3. Torna nell'app e premi **Accedi**. Vedrai il planning vuoto.

## 6. Importa i tuoi dati attuali

1. In Supabase apri **SQL Editor → New query**.
2. Copia tutto il file `supabase/import-dati-attuali.sql`, incollalo e premi **Run**.
3. Ricarica l'app: trovi Virginia, Daniele, Jessica, Giuseppe, Aïnhoa, Eliana e Noelie, con tariffe, massimi e i turni della settimana 48.

Lo script funziona solo una volta: se il locale ha già dipendenti si ferma, per non creare doppioni.
Se nel frattempo cambi i turni nella vecchia versione su Claude, chiedimi di rigenerare questo file.

## 7. Chiudi le iscrizioni (consigliato)

Finché non vendi Rush ad altri locali, impedisci a sconosciuti di creare account:
**Authentication → Sign In / Providers** → disattiva **Allow new users to sign up**.
(Anche se qualcuno si iscrivesse, vedrebbe solo un locale vuoto suo: i tuoi dati restano protetti.)

## 8. Manda i link ai dipendenti

1. Nell'app apri la scheda **Link staff**.
2. Per ognuno premi **WhatsApp**: si apre WhatsApp con un messaggio pronto e il suo link personale.
3. Il dipendente apre il link dal telefono e vede subito i suoi turni: **nessun account, nessuna password**.
4. Se qualcuno lascia il team: **Disattiva** (il link smette di funzionare subito) o **Nuovo link**.

## 9. Installa l'app sul telefono

- **iPhone (Safari):** apri l'indirizzo → tasto **Condividi** → **Aggiungi alla schermata Home**.
- **Android (Chrome):** apri l'indirizzo → **⋮** → **Installa app** / **Aggiungi a schermata Home**.

Vale anche per i dipendenti con il loro link: avranno l'icona "Turni" che apre direttamente i loro turni.

---

## Da sapere

- **Piano gratuito Supabase:** se il progetto non viene usato per 7 giorni, Supabase lo mette in pausa (i dati restano; si riattiva da Supabase con **Resume project**). Con l'uso quotidiano non succede. Il piano Pro costa 25 $/mese e non va mai in pausa, e include backup giornalieri.
- **Aggiornamenti:** quando ti mando una nuova versione, in Cloudflare apri il progetto → **Create deployment** → trascina di nuovo la cartella `app`. Tieni sempre il tuo `config.js`.
- **Dominio tuo (es. rush.be):** in Cloudflare, progetto → **Custom domains**. Poi aggiorna Site URL e Redirect URLs in Supabase.
- **Sicurezza:** i dipendenti vedono solo nome, turni e colleghi in turno con loro. Tariffe, budget e massimi sono leggibili solo da te. Ogni locale vede solo i propri dati.

---

## Aggiornamento: ferie, giorni liberi e disponibilità

Da fare **una sola volta**, prima o subito dopo aver pubblicato la nuova versione dell'app.

1. In Supabase apri **SQL Editor → New query**.
2. Copia tutto il file `supabase/aggiornamento-richieste.sql`, incollalo e premi **Run**.
   Deve comparire "Success. No rows returned". Se lo rilanci per sbaglio non succede niente: non cancella dati.
3. Ricarica l'app.

Cosa cambia:
- **Dipendenti** (dal loro link): scheda **Ferie e giorni liberi** per chiedere uno o più giorni e vedere se la richiesta è approvata o rifiutata. Possono annullare le richieste ancora in attesa.
- **Studenti**: in più la scheda **Disponibilità**, settimana per settimana, giorno per giorno: tutto il giorno, solo pranzo, solo cena o non disponibile, con una nota. Fino a 14 settimane in anticipo.
- **Tu** (admin): nuova scheda **Richieste** con le richieste da approvare o rifiutare (con motivo), le disponibilità degli studenti per settimana e lo storico. Con **Aggiungi assenza** inserisci tu un'assenza già approvata.
- **Planning**: ogni casella mostra ferie, giorni liberi e disponibilità. Se metti un turno a chi è in ferie la casella diventa rossa; se la richiesta è in attesa o il turno è fuori dalla disponibilità dello studente diventa gialla. Il turno si può comunque salvare.

Se pubblichi l'app prima di aver fatto il passo 2, tutto il resto continua a funzionare: la scheda Richieste ti ricorda di eseguire il file.

---

## Aggiornamento: cambi turno tra colleghi

Da fare **una sola volta**: in Supabase apri **SQL Editor → New query**, incolla tutto il file `supabase/aggiornamento-cambi.sql` e premi **Run** ("Success. No rows returned"). Rilanciarlo non cancella niente.

Come funziona:
1. Il dipendente, dal suo link, apre **Cambi** e sceglie uno dei suoi turni delle prossime 6 settimane e un collega **dello stesso reparto**. Poi sceglie se **cedergli il turno** o fare uno **scambio** con un turno del collega.
2. Il collega trova la richiesta in **Cambi → Richieste per te** e preme **Accetta** o **Rifiuta**.
3. Se accetta, la richiesta arriva a te in **Richieste → Cambi turno da approvare**, con gli avvisi utili: sovrapposizioni con altri turni, ferie, disponibilità degli studenti, turni modificati nel frattempo.
4. Premi **Approva** e i turni si spostano da soli nel planning, oppure **Rifiuta** con un motivo che vedono entrambi.

Chi ha chiesto può annullare finché non hai deciso. Se nel frattempo modifichi o elimini uno dei turni coinvolti, l'approvazione viene bloccata per sicurezza: rifiuta il cambio e fanne fare uno nuovo.

---

## Aggiornamento: badgeuse (timbrature con tablet e PIN)

**1. Database (una sola volta).** In Supabase apri **SQL Editor → New query**, incolla tutto `supabase/aggiornamento-badgeuse.sql` e premi **Run**.

**2. Collega il tablet del ristorante.**
- In Rush vai su **Impostazioni → Badgeuse → Collega un tablet**: il link viene creato e copiato.
- Mandalo al tablet (email o WhatsApp) e aprilo con **Chrome**. **Aprilo solo sul tablet**: il primo dispositivo che apre il link resta collegato e il link non funziona su nessun altro telefono o computer.
- Se cambi tablet, o se sul tablet vengono cancellati i dati di Chrome, premi **Scollega tablet** e riapri il link sul tablet giusto.
- Nel menu ⋮ di Chrome scegli **Aggiungi a schermata Home** (o **Installa app**): la badgeuse si apre a schermo intero.
- Consigliato: in Impostazioni Android attiva **Blocco su schermo/Fissa app** (Sicurezza → Altre impostazioni), così il tablet resta sulla badgeuse.
- Ogni ristorante ha il suo Rush, quindi crei il link dal Rush di quel ristorante.

**3. PIN.** In **Impostazioni → PIN dei dipendenti** imposta un PIN di 4 cifre per ognuno (anche generato a caso). Il PIN si vede una sola volta: comunicalo di persona. Se qualcuno lo dimentica, ne imposti uno nuovo. Dopo 5 PIN sbagliati il dipendente resta bloccato per 15 minuti (oppure finché non imposti un nuovo PIN).

**Come timbrano.** Toccano il proprio nome e inseriscono il PIN: Rush decide da solo se è un'entrata o un'uscita. Vale l'ora del server, non quella del tablet. Se manca internet, il tablet dice chiaramente che la timbratura **non** è stata registrata.

**Scheda Presenze.** Per ogni mese e dipendente vedi entrate, uscite, pausa (quella del planning), ore effettive e pianificate, con le anomalie: uscita o entrata mancante, turno senza timbrature. Le correzioni (**+ uscita**, **Aggiungi timbratura**, **Annulla timbratura**) chiedono sempre un motivo e restano nel registro con data e autore. Le timbrature non si possono cancellare, nemmeno eliminando il dipendente.

**Export.**
- **Tabella paghe (CSV)**: una riga per giorno e i totali per dipendente, da mandare a chi fa le fiches de paie. Si apre con Excel.
- **Registro completo (CSV)**: tutte le timbrature con correzioni e annullamenti. Conservalo per almeno 5 anni.

Da sapere: questo registro interno non sostituisce la registrazione delle presenze per l'ONSS tramite caisse enregistreuse (SCE) o SAE, se il ristorante usa la riduzione contributi horeca. Prima di usarla in produzione falla validare dal segretariato sociale e informa i dipendenti (cosa viene registrato, perché e per quanto tempo).

