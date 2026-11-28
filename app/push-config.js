// Rush · chiave PUBBLICA per le notifiche push (può stare nel repository).
// La chiave privata corrispondente è solo nei segreti di Supabase.
window.RUSH_CONFIG = Object.assign(window.RUSH_CONFIG || {}, {
  // nome (slug) della funzione su Supabase → Edge Functions
  notifyFunction: "Notifie",
  vapidPublicKey: "BPItC34DN86W2fqOAaeNbCBNpEnjLTUR6d_7XsdqQ9QhOE1XCY_Kkb9BuRqYWs6KyCf_at1PkFxLGKod4RZfDVU"
});
