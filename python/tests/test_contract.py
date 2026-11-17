import json
from pathlib import Path
import pytest

from nativehtmlkit_appshell.contract import validate_manifest, validate_view, validate_result, ContractError

FIX = Path(__file__).resolve().parents[2] / "fixtures"


def load(path):
    return json.loads((FIX / path).read_text("utf-8"))


def test_positive_fixtures():
    m = validate_manifest(load("valid/manifest.json"))
    v = validate_view(load("valid/view.json"), m)
    assert m["api_version"] == 1
    assert len(v["blocks"]) > 0


@pytest.mark.parametrize("filename", [
    "manifest-bad-id.json", "manifest-duplicate-page.semantic.json",
    "manifest-missing-confirmation.json", "manifest-unsupported-version.json"])
def test_manifest_negative_fixtures(filename):
    with pytest.raises(ContractError):
        validate_manifest(load("invalid/" + filename))


@pytest.mark.parametrize("filename", [
    "view-bad-heading-level.json", "view-raw-html.json", "view-unknown-command.semantic.json"])
def test_view_negative_fixtures(filename):
    m = validate_manifest(load("valid/manifest.json"))
    with pytest.raises(ContractError):
        validate_view(load("invalid/" + filename), m)


def test_foreign_fields_rejected():
    m = load("valid/manifest.json")
    m["exec"] = "danger"
    with pytest.raises(ContractError): validate_manifest(m)


def test_nonfinite_values_rejected():
    with pytest.raises(ContractError): validate_result({"message": "x", "refresh": False, "meta": float("nan")})


def test_reject_duplicate_fields_and_excessive_depth():
    m = load("valid/manifest.json")
    v = {"title": "x", "blocks": [{"kind": "input", "name": "x", "label": "X"},
                                    {"kind": "input", "name": "x", "label": "X"}]}
    with pytest.raises(ContractError): validate_view(v, m)
    v = {"title": "x", "blocks": [{"kind": "text", "text": "x"}]}
    for _ in range(12): v = {"title": "x", "blocks": [{"kind": "card", "children": v["blocks"]}]}
    with pytest.raises(ContractError): validate_view(v, m)


def test_manifest_version_and_id_must_match_distribution():
    m = load("valid/manifest.json")
    with pytest.raises(ContractError): validate_manifest(m, expected_version="7.3")
    with pytest.raises(ContractError): validate_manifest(m, expected_id="org.other.hello")
