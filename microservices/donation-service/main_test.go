package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// TestHealthHandler valida que /health responde 200 com o servico esperado.
func TestHealthHandler(t *testing.T) {
	app := &App{}

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()

	app.HealthHandler(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("esperado status 200, recebido %d", resp.StatusCode)
	}

	var body map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("falha decodificando JSON: %v", err)
	}

	if body["status"] != "ok" {
		t.Errorf("esperado status=ok, recebido %q", body["status"])
	}
	if body["service"] != "donation-service" {
		t.Errorf("esperado service=donation-service, recebido %q", body["service"])
	}
}

// TestDonationHandlerRejectsMethodNotAllowed garante que /donations bloqueia DELETE.
func TestDonationHandlerRejectsMethodNotAllowed(t *testing.T) {
	app := &App{}

	req := httptest.NewRequest(http.MethodDelete, "/donations", nil)
	w := httptest.NewRecorder()

	app.DonationHandler(w, req)

	if w.Result().StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("esperado 405, recebido %d", w.Result().StatusCode)
	}
}
