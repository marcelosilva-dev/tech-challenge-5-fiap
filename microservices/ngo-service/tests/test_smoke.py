"""Smoke tests minimos para a CI. Cobre o /health sem precisar de DB real."""
import os
import sys
from unittest.mock import patch, MagicMock

# Garante que app.py seja importavel
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def test_health_endpoint_returns_ok():
    """Valida que /health responde 200 e contem o servico esperado."""
    with patch.dict(os.environ, {"DATABASE_URL": "postgres://fake:fake@localhost:5432/fake"}):
        with patch("psycopg2.pool.SimpleConnectionPool", return_value=MagicMock()):
            from app import app
            with app.test_client() as client:
                response = client.get("/health")
                assert response.status_code == 200
                data = response.get_json()
                assert data["status"] == "ok"
                assert data["service"] == "ngo-service"


def test_create_ngo_requires_all_fields():
    """Valida que POST /ngos falha com 400 quando faltam campos obrigatorios."""
    with patch.dict(os.environ, {"DATABASE_URL": "postgres://fake:fake@localhost:5432/fake"}):
        with patch("psycopg2.pool.SimpleConnectionPool", return_value=MagicMock()):
            from app import app
            with app.test_client() as client:
                response = client.post("/ngos", json={"name": "Apenas Nome"})
                assert response.status_code == 400
                assert "obrigat" in response.get_json()["error"].lower()
