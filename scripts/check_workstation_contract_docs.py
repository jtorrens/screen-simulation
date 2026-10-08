#!/usr/bin/env python3
"""Reject stale workstation contract versions in active architecture documents."""
from pathlib import Path
import re

from check_decision_authority import DecisionAuthorityError, _active_documents

SOURCE = Path("apps/screen-native-macos/Sources/ScreenSimulationNative")


def current_versions(root: Path) -> dict[str, int]:
    scenes = (root / SOURCE / "SceneLibrary.swift").read_text()
    global_library = (root / SOURCE / "GlobalLibrary.swift").read_text()
    queue = (root / SOURCE / "RenderQueueStore.swift").read_text()
    animation = (root / SOURCE / "SceneAnimation.swift").read_text()

    def number(source: str, pattern: str) -> int:
        values = set(re.findall(pattern, source))
        if len(values) != 1:
            raise DecisionAuthorityError(f"Ambiguous current workstation contract: {pattern}")
        return int(values.pop())

    return {
        "GlobalLibrary": number(global_library, r"currentSchemaVersion = (\d+)"),
        "Scenes": number(scenes, r"currentSchemaVersion = (\d+)"),
        "SavedScene": number(scenes, r'static let schema = "ScreenSimulation.SavedScene.v(\d+)"'),
        "SceneAuthoring": number(scenes, r'static let schema = "ScreenSimulation.SceneAuthoring.v(\d+)"'),
        "SceneAutosave": number(scenes, r'static let schema = "ScreenSimulation.SceneAutosave.v(\d+)"'),
        "Autosave": number(scenes, r'"Autosave.v(\d+)"'),
        "RenderQueue": number(queue, r'static let schema = "ScreenSimulation.RenderQueue.v(\d+)"'),
        "SceneAnimation": number(animation, r'static let schema = "ScreenSimulation.SceneAnimation.v(\d+)"'),
    }


def validate_text(text: str, versions: dict[str, int], path: str) -> None:
    for family, expected in versions.items():
        spelling = {
            "SavedScene": r"Saved ?Scene",
            "SceneAuthoring": r"Scene ?Authoring",
            "RenderQueue": r"(?:Render ?Queue|Queue)",
        }.get(family, family)
        for match in re.finditer(r"(?<![A-Za-z])" + spelling + r"[. ]v(\d+)\b", text):
            if int(match.group(1)) != expected:
                raise DecisionAuthorityError(
                    f"{path}: stale {match.group(0)}; current {family} is v{expected}"
                )
    if re.search(r"\bv\d+(?:-to-v\d+|→v?\d+)\b", text):
        raise DecisionAuthorityError(f"{path}: migration ledger in active architecture")


def validate(root: Path) -> None:
    versions = current_versions(root)
    for relative in sorted(_active_documents(root)):
        validate_text((root / relative).read_text(), versions, relative)


if __name__ == "__main__":
    validate(Path(__file__).resolve().parents[1])
    print("current workstation documentation gate passed")
