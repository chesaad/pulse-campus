// Service notif — application net/http minimaliste.
//
// CRUD en mémoire sur des "events" de notification. Aucune persistance,
// aucune base : l'objectif du TP est sur l'observabilité, pas sur le stockage.
//
// Ce fichier configure :
//   - le middleware Prometheus (cf. metrics.go) ;
//   - quelques routes métier (/events, /events/{id}) ;
//   - les routes /healthz et /metrics requises par Kubernetes et Prometheus.
package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Variables injectées au build via -ldflags (cf. Dockerfile).
var (
	Version = "dev"
	Commit  = "unknown"
)

type Event struct {
	ID      int    `json:"id"`
	Type    string `json:"type"`
	Message string `json:"message"`
}

var (
	mu      sync.Mutex
	events  = []Event{
		{ID: 1, Type: "info", Message: "Bienvenue sur DevHub Campus"},
		{ID: 2, Type: "warning", Message: "Maintenance planifiée samedi"},
	}
	failRate = parseFailRate()
)

func parseFailRate() float64 {
	v, err := strconv.ParseFloat(os.Getenv("FAIL_RATE"), 64)
	if err != nil {
		return 0
	}
	return v
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// Routeur simple à la main pour rester en stdlib.
// Le pattern de chaque route est enregistré dans `routePattern` afin que le
// middleware Prometheus puisse l'utiliser comme label `route` sans risquer
// d'exploser la cardinalité.
type route struct {
	method  string
	pattern string                                           // pattern littéral ou avec ":id"
	handler func(w http.ResponseWriter, r *http.Request)
}

var routes = []route{
	{"GET", "/events", listEvents},
	{"GET", "/events/:id", getEvent},
	{"POST", "/events", createEvent},
	{"GET", "/break", breakEndpoint},
	{"GET", "/healthz", healthz},
	{"GET", "/readyz", healthz},
}

// match renvoie la route correspondant à la requête et son pattern normalisé.
func match(r *http.Request) (*route, string, bool) {
	for i := range routes {
		rt := &routes[i]
		if rt.method != r.Method {
			continue
		}
		if rt.pattern == r.URL.Path {
			return rt, rt.pattern, true
		}
		// Support très simple d'un seul :id à la fin.
		if strings.HasSuffix(rt.pattern, "/:id") {
			prefix := strings.TrimSuffix(rt.pattern, "/:id")
			if strings.HasPrefix(r.URL.Path, prefix+"/") {
				return rt, rt.pattern, true
			}
		}
	}
	return nil, "", false
}

// dispatch est le handler racine : il route, mesure, et délègue.
func dispatch(w http.ResponseWriter, r *http.Request) {
	// /metrics est géré séparément, hors de la chaîne mesurée.
	if r.URL.Path == "/metrics" {
		metricsHandler().ServeHTTP(w, r)
		return
	}

	rt, pattern, ok := match(r)
	if !ok {
		// Pas de route matchée : on enregistre la métrique sur "unknown"
		// pour signaler l'anomalie sans exploser la cardinalité.
		measure(w, r, "unknown", func(w http.ResponseWriter, r *http.Request) {
			http.NotFound(w, r)
		})
		return
	}
	measure(w, r, pattern, rt.handler)
}

// Handlers métier.

func listEvents(w http.ResponseWriter, _ *http.Request) {
	mu.Lock()
	defer mu.Unlock()
	recordBusinessEvent("list_events")
	writeJSON(w, http.StatusOK, events)
}

func getEvent(w http.ResponseWriter, r *http.Request) {
	idStr := strings.TrimPrefix(r.URL.Path, "/events/")
	id, err := strconv.Atoi(idStr)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad_id"})
		return
	}
	mu.Lock()
	defer mu.Unlock()
	for _, e := range events {
		if e.ID == id {
			writeJSON(w, http.StatusOK, e)
			return
		}
	}
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "not_found"})
}

func createEvent(w http.ResponseWriter, r *http.Request) {
	var e Event
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "bad_body"})
		return
	}
	if e.Type == "" || e.Message == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "type et message requis"})
		return
	}
	mu.Lock()
	defer mu.Unlock()
	if len(events) > 0 {
		e.ID = events[len(events)-1].ID + 1
	} else {
		e.ID = 1
	}
	events = append(events, e)
	recordBusinessEvent("create_event")
	writeJSON(w, http.StatusCreated, map[string]int{"id": e.ID})
}

// breakEndpoint sert à simuler une régression (étape 7).
func breakEndpoint(w http.ResponseWriter, _ *http.Request) {
	if rand.Float64() < failRate {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "boom"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "service": "notif"})
}

func main() {
	rand.Seed(time.Now().UnixNano())

	initMetrics(Version, Commit)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", dispatch)

	addr := ":" + port
	log.Printf(`{"t":%q,"level":"info","msg":"notif up on %s"}`, time.Now().UTC().Format(time.RFC3339), addr)
	srv := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}
	if err := srv.ListenAndServe(); err != nil {
		log.Fatal(fmt.Errorf("server crashed: %w", err))
	}
}
