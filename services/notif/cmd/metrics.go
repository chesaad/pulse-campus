// Middleware Prometheus pour le service notif (Go).
//
// Ce que ce fichier émet, conforme à la convention RED documentée dans le poly :
//   - http_requests_total                  (Counter)
//   - http_request_duration_seconds        (Histogram, buckets configurables via env)
//   - notif_build_info                     (Gauge constante = 1, métadonnées de release)
//   - business_event_total (optionnel)     (Counter, activable par env)
//
// Labels normalisés :
//   - method        : GET, POST, PUT, ...
//   - route         : pattern de route (ex. "/events/:id"), JAMAIS l'URL brute.
//                     En Go avec net/http, il n'y a PAS de "matched route" disponible
//                     en standard ; c'est `dispatch` (cf. main.go) qui passe le pattern
//                     littéral au middleware. Ne JAMAIS utiliser r.URL.Path.
//   - status_class  : "2xx", "3xx", "4xx", "5xx" — groupé.

package main

import (
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	registry = prometheus.NewRegistry()

	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Nombre total de requêtes HTTP servies.",
		},
		[]string{"method", "route", "status_class"},
	)

	httpRequestDuration *prometheus.HistogramVec

	buildInfo = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "notif_build_info",
			Help: "Métadonnées de release du service (version, commit, langage). Vaut toujours 1.",
		},
		[]string{"version", "commit", "language"},
	)

	businessEventTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "business_event_total",
			Help: "Compteur d'événements métier applicatifs (activable via METRICS_BUSINESS_ENABLED).",
		},
		[]string{"kind"},
	)

	businessEnabled = strings.EqualFold(os.Getenv("METRICS_BUSINESS_ENABLED"), "true")
)

// initMetrics initialise les compteurs avec les buckets lus depuis l'env
// et inscrit toutes les métriques au registre dédié.
func initMetrics(version, commit string) {
	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "Durée des requêtes HTTP en secondes.",
			Buckets: parseBuckets(),
		},
		[]string{"method", "route", "status_class"},
	)

	registry.MustRegister(
		httpRequestsTotal,
		httpRequestDuration,
		buildInfo,
		businessEventTotal,
		// Métriques process Go et runtime.
		prometheus.NewGoCollector(),
		prometheus.NewProcessCollector(prometheus.ProcessCollectorOpts{}),
	)

	buildInfo.WithLabelValues(version, commit, "go").Set(1)
}

// parseBuckets lit METRICS_BUCKETS = "0.05,0.1,...,5" depuis l'env.
// Les étudiants alignent ces buckets sur leur SLO de latence en étape 2.
func parseBuckets() []float64 {
	raw := os.Getenv("METRICS_BUCKETS")
	if raw == "" {
		raw = "0.05,0.1,0.2,0.3,0.5,1,2,5"
	}
	parts := strings.Split(raw, ",")
	out := make([]float64, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		v, err := strconv.ParseFloat(p, 64)
		if err != nil || v <= 0 {
			continue
		}
		out = append(out, v)
	}
	if len(out) == 0 {
		return []float64{0.05, 0.1, 0.2, 0.3, 0.5, 1, 2, 5}
	}
	sort.Float64s(out)
	return out
}

// statusRecorder enveloppe ResponseWriter pour capturer le code de retour.
type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (s *statusRecorder) WriteHeader(code int) {
	s.status = code
	s.ResponseWriter.WriteHeader(code)
}

func statusClass(code int) string {
	switch {
	case code >= 500:
		return "5xx"
	case code >= 400:
		return "4xx"
	case code >= 300:
		return "3xx"
	case code >= 200:
		return "2xx"
	default:
		return "1xx"
	}
}

// measure encapsule un handler avec la mesure Prometheus.
// `routePattern` est le pattern littéral (ex. "/events/:id"), fourni par
// le dispatcher — pas l'URL brute, pour éviter l'explosion de cardinalité.
func measure(w http.ResponseWriter, r *http.Request, routePattern string, handler func(http.ResponseWriter, *http.Request)) {
	sr := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
	start := time.Now()
	handler(sr, r)
	elapsed := time.Since(start).Seconds()

	labels := prometheus.Labels{
		"method":       r.Method,
		"route":        routePattern,
		"status_class": statusClass(sr.status),
	}
	httpRequestsTotal.With(labels).Inc()
	httpRequestDuration.With(labels).Observe(elapsed)
}

func metricsHandler() http.Handler {
	return promhttp.HandlerFor(registry, promhttp.HandlerOpts{Registry: registry})
}

func recordBusinessEvent(kind string) {
	if businessEnabled {
		businessEventTotal.WithLabelValues(kind).Inc()
	}
}
