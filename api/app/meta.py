"""Valid parameter values, loaded from the database once at start-up.

The time bands (res.bands) and speed scenarios (net.scenarios) are defined by the data pipeline,
so the API validates requests against what was actually computed.
"""

from dataclasses import dataclass, field

from fastapi import HTTPException

from app.db import fetch_all


@dataclass
class Meta:
    bands: dict[str, list[int]] = field(default_factory=dict)  # mode -> minutes
    scenarios: dict[str, str] = field(default_factory=dict)  # scenario -> walk | drive | both

    def load(self) -> None:
        bands: dict[str, list[int]] = {}
        rows = fetch_all("SELECT mode, minutes FROM res.bands ORDER BY mode, minutes")
        for mode, minutes in rows:
            bands.setdefault(mode, []).append(minutes)
        self.bands = bands
        self.scenarios = dict(
            fetch_all("SELECT scenario, applies_to FROM net.scenarios ORDER BY scenario")
        )

    def check_band(self, mode: str, minutes: int, scenario: str) -> None:
        """Raise HTTP 422 with a helpful message for an invalid mode/minutes/scenario."""
        allowed = self.bands.get(mode, [])
        if minutes not in allowed:
            raise HTTPException(
                422, f"minutes={minutes} is not available for mode={mode}; choose one of {allowed}"
            )
        self.check_scenario(mode, scenario)

    def check_scenario(self, mode: str, scenario: str) -> None:
        """Raise HTTP 422 if the scenario does not exist or does not apply to the mode."""
        applies_to = self.scenarios.get(scenario)
        if applies_to is None:
            raise HTTPException(
                422, f"Unknown scenario '{scenario}'; choose one of {sorted(self.scenarios)}"
            )
        if applies_to not in (mode, "both"):
            usable = sorted(s for s, a in self.scenarios.items() if a in (mode, "both"))
            raise HTTPException(
                422,
                f"Scenario '{scenario}' applies to {applies_to} only; for mode={mode} use one of "
                f"{usable}",
            )


meta = Meta()
