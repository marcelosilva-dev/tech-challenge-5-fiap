"""Smoke tests minimos para a CI. Cobre o /health sem precisar de DynamoDB real."""
import os
import sys
from unittest.mock import patch, MagicMock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def test_health_endpoint_returns_ok():
    """Valida que /health responde 200 e contem o servico esperado."""
    with patch.dict(os.environ, {"AWS_DYNAMODB_TABLE": "FakeTable"}):
        with patch("boto3.resource") as mock_boto:
            mock_boto.return_value.Table.return_value = MagicMock()
            from app import app
            with app.test_client() as client:
                response = client.get("/health")
                assert response.status_code == 200
                data = response.get_json()
                assert data["status"] == "ok"
                assert data["service"] == "volunteer-service"


def test_register_volunteer_requires_all_fields():
    """Valida que POST /volunteers falha com 400 quando faltam campos obrigatorios."""
    with patch.dict(os.environ, {"AWS_DYNAMODB_TABLE": "FakeTable"}):
        with patch("boto3.resource") as mock_boto:
            mock_boto.return_value.Table.return_value = MagicMock()
            from app import app
            with app.test_client() as client:
                response = client.post("/volunteers", json={"name": "Apenas Nome"})
                assert response.status_code == 400
                assert "obrigat" in response.get_json()["error"].lower()
