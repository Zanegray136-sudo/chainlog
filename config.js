// ChainLog settings.
// The publishable key is meant to be public — your data is protected by the database rules in schema.sql.
window.CHAINLOG_CONFIG = {
  SUPABASE_URL: "https://ksaeffrwrukvabfsqkpc.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_DtEwDsIC3cIoTlpWd04IVg_aiJciF3k",

  APP_NAME: "ChainLog",
  INSPECTION_DAYS: 182,     // periodic inspection every ~6 months
  LOADTEST_DAYS: 365,       // load test every 12 months
  DUE_SOON_DAYS: 14,        // flag inspections due within this many days
  FAULT_ALERT_DAYS: 60      // alert when a motor has been faulty this long

  // To change the inspection checklist, add a list here, e.g.
  // , CHECKLIST: ["Hook & latch", "Load chain", "Brake", "Limit switches", "Controls", "Cables & plugs", "Body & suspension", "Labels"]
};
