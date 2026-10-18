"""
app/integration/component1_runtime.py

Thin wrapper so the MQTT subscriber can get Component 1's trained
models without duplicating training logic — it just delegates to
app.component1.ml.model_loader, which loads pre-trained artifacts
if present, or trains once and caches them.
"""

from typing import Any, Dict

from app.component1.ml.model_loader import component1_loader


class Component1Runtime:
    def load(self) -> Dict[str, Any]:
        return component1_loader.load()


component1_runtime = Component1Runtime()
