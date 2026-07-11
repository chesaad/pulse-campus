// Service annuaire — application Express minimaliste.
// CRUD en mémoire sur des étudiants. Aucune persistance, aucune base de données :
// l'objectif pédagogique du TP est sur l'observabilité, pas sur le stockage.
//
// Ce fichier configure :
//   - le middleware Prometheus (cf. src/metrics.js) ;
//   - quelques routes métier (/students, /students/:id) ;
//   - les routes /healthz et /metrics requises par Kubernetes et Prometheus.

const express = require('express');
const { metricsMiddleware, metricsHandler, recordBusinessEvent } = require('./metrics');

const PORT = parseInt(process.env.PORT || '8080', 10);
const LOG_LEVEL = (process.env.LOG_LEVEL || 'info').toLowerCase();
const FAIL_RATE = parseFloat(process.env.FAIL_RATE || '0'); // 0..1 — injecte du 500 pour tester un canary KO

const levels = { debug: 0, info: 1, warn: 2, error: 3 };
function log(level, msg) {
  if ((levels[level] ?? 1) >= (levels[LOG_LEVEL] ?? 1)) {
    console.log(JSON.stringify({ t: new Date().toISOString(), level, msg }));
  }
}

// Données métier en mémoire — volontairement minimalistes.
const students = [
  { id: 1, nom: 'Adèle Ferrand', promo: 'M2 IW' },
  { id: 2, nom: 'Bachir Saadi', promo: 'M2 IW' },
  { id: 3, nom: 'Claire Dupond', promo: 'M2 IW' },
];

const app = express();
app.use(express.json());

// Le middleware Prometheus DOIT être enregistré avant les routes.
app.use(metricsMiddleware);

// Routes métier.
app.get('/students', (_req, res) => {
  recordBusinessEvent('list_students');
  res.json(students);
});

app.get('/students/:id', (req, res) => {
  const id = parseInt(req.params.id, 10);
  const s = students.find((x) => x.id === id);
  if (!s) return res.status(404).json({ error: 'not_found' });
  res.json(s);
});

app.post('/students', (req, res) => {
  const { nom, promo } = req.body || {};
  if (!nom || !promo) return res.status(400).json({ error: 'nom et promo requis' });
  const id = (students[students.length - 1]?.id || 0) + 1;
  students.push({ id, nom, promo });
  recordBusinessEvent('create_student');
  res.status(201).json({ id });
});

// Endpoint utilisé en étape 7 pour simuler une régression et tester le rollback automatique.
app.get('/break', (_req, res) => {
  if (Math.random() < FAIL_RATE) return res.status(500).json({ error: 'boom' });
  res.json({ ok: true });
});

// Probes Kubernetes.
app.get('/healthz', (_req, res) => res.json({ ok: true, service: 'annuaire' }));
app.get('/readyz', (_req, res) => res.json({ ok: true, service: 'annuaire' }));

// Endpoint Prometheus.
app.get('/metrics', metricsHandler);

app.listen(PORT, () => log('info', `annuaire up on :${PORT}`));
log('debug', `LOG_LEVEL=${LOG_LEVEL} FAIL_RATE=${FAIL_RATE}`);
