"""Explicit, fail-closed identities for device-writing test tools (no I/O)."""
import argparse
from dataclasses import dataclass


@dataclass(frozen=True)
class TestTarget:
    bundle_id: str
    scheme: str
    configuration: str


def validate_target(bundle_id, scheme, authorized):
    # WOOW Debug shares production identity. Neither it nor either production
    # Apporo identity is a safe destination for reset/install/test operations.
    if bundle_id != "com.apporo.odoo.dev" or scheme != "apporoodoo":
        raise ValueError("Only the isolated Apporo dev bundle/scheme may be targeted; WOOW and production are protected")
    if not authorized:
        raise ValueError("Device writes require explicit --authorize-device-writes approval")
    return TestTarget(bundle_id, scheme, "ApporoDebug")


def require_authorized_target(argv=None):
    parser = argparse.ArgumentParser(description="Device-writing verification; requires separate owner authorization")
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--scheme", required=True)
    parser.add_argument("--authorize-device-writes", action="store_true")
    args = parser.parse_args(argv)
    try:
        return validate_target(args.bundle_id, args.scheme, args.authorize_device_writes)
    except ValueError as error:
        parser.error(str(error))


def block_legacy_live_e2e():
    # No bypass: changing an app bundle does not repair hardcoded backend rows,
    # tenant identities or credentials in the preserved legacy implementation.
    raise SystemExit("BLOCKED: legacy live E2E tenant/row/config isolation is incomplete; no device, credential or network access is permitted. Requires separately approved stage-3 repair.")
