// Middleware Prometheus pour le service annuaire.
//
// Ce que ce fichier émet, conforme à la convention RED documentée dans le poly :
//   - http_requests_total                  (Counter)
//   - http_request_duration_seconds        (Histogram, buckets configurables via env)
//   - annuaire_build_info                  (Gauge constante = 1, métadonnées de release)
//   - business_event_total (optionnel)     (Counter, activable par env)
//
// Labels normalisés :
//   - method        : GET, POST, PUT, ...
//   - route         : pattern Express (ex. "/students/:id"), JAMAIS l'URL brute,
//                     pour ne pas exploser la cardinalité.
//   - status_class  : "2xx", "3xx", "4xx", "5xx" — groupé pour la même raison.

const client = require('prom-client');

const VERSION = process.env.VERSION || 'dev';
const COMMIT = process.env.COMMIT || 'unknown';
const BUSINESS_ENABLED = (process.env.METRICS_BUSINESS_ENABLED || 'false').toLowerCase() === 'true';

// Buckets configurables via env METRICS_BUCKETS = "0.05,0.1,0.2,0.3,0.5,1,2,5".
// Les étudiants alignent ces buckets sur leur SLO de latence en étape 2.
function parseBuckets() {
  const raw = process.env.METRICS_BUCKETS || '0.05,0.1,0.2,0.3,0.5,1,2,5';
  const parsed = raw
    .split(',')
    .map((s) => parseFloat(s.trim()))
    .filter((n) => Number.isFinite(n) && n > 0)
    .sort((a, b) => a - b);
  return parsed.length > 0 ? parsed : [0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5];
}

const registry = new client.Registry();
client.collectDefaultMetrics({ register: registry });

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Nombre total de requêtes HTTP servies.',
  labelNames: ['method', 'route', 'status_class'],
  registers: [registry],
});

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Durée des requêtes HTTP en secondes.',
  labelNames: ['method', 'route', 'status_class'],
  buckets: parseBuckets(),
  registers: [registry],
});

const buildInfo = new client.Gauge({
  name: 'annuaire_build_info',
  help: "Métadonnées de release du service (version, commit, langage). Vaut toujours 1.",
  labelNames: ['version', 'commit', 'language'],
  registers: [registry],
});
buildInfo.set({ version: VERSION, commit: COMMIT, language: 'nodejs' }, 1);

const businessEventTotal = new client.Counter({
  name: 'business_event_total',
  help: "Compteur d'événements métier applicatifs (activable via METRICS_BUSINESS_ENABLED).",
  labelNames: ['kind'],
  registers: [registry],
});

// Regroupe un code HTTP en classe ("2xx", "3xx", ...).
function statusClass(code) {
  if (code >= 500) return '5xx';
  if (code >= 400) return '4xx';
  if (code >= 300) return '3xx';
  if (code >= 200) return '2xx';
  return '1xx';
}

// Normalise la route observée.
//   - on PRÉFÈRE req.route.path (pattern matché par Express, ex. "/students/:id") ;
//   - à défaut (404 ou routeur monté), on retombe sur req.path,
//     ce qui peut produire de la cardinalité — c'est volontaire pour signaler
//     l'anomalie aux équipes plutôt que de l'écraser.
function normalizeRoute(req) {
  const matched = req.route && req.route.path;
  if (matched) {
    if (req.baseUrl) return req.baseUrl + matched;
    return matched;
  }
  return req.path || 'unknown';
}

function metricsMiddleware(req, res, next) {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const route = normalizeRoute(req);
    const labels = {
      method: req.method,
      route,
      status_class: statusClass(res.statusCode),
    };
    httpRequestsTotal.inc(labels);
    const seconds = Number(process.hrtime.bigint() - start) / 1e9;
    httpRequestDuration.observe(labels, seconds);
  });
  next();
}

async function metricsHandler(_req, res) {
  res.setHeader('Content-Type', registry.contentType);
  res.send(await registry.metrics());
}

function recordBusinessEvent(kind) {
  if (BUSINESS_ENABLED) businessEventTotal.inc({ kind });
}

module.exports = { metricsMiddleware, metricsHandler, recordBusinessEvent, registry };
