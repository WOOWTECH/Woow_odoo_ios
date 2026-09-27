"""Settings PIN gates are wired in the views, not only in the ViewModel. No Xcode, devices or network.

The ViewModel rules are covered by XCTest (AppLockDisableRequiresPinTests,
ChangePinRequiresCurrentPinTests). What XCTest cannot see is whether the SwiftUI views route
through them: PinSetupView used to own a separate SettingsViewModel for its `.verifyOld` step, so
a verification there could never authorize the `setPin` of SettingsView's ViewModel.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def code(path):
    """Source without `//` comment lines and without previews."""
    source = (ROOT / path).read_text().split("#Preview", 1)[0]
    return "\n".join(line for line in source.splitlines() if not line.strip().startswith("//"))


class SettingsPinGateWiringTests(unittest.TestCase):
    def test_app_lock_off_goes_through_the_current_pin_prompt(self):
        view = code("odoo/UI/Settings/SettingsView.swift")
        self.assertIn("if !viewModel.toggleAppLock(enabled) { showAppLockDisable = true }", view)
        self.assertIn("verify: { viewModel.disableAppLock(verifyingCurrentPin: $0) }", view)
        self.assertIn('subtitle: String(localized: "app_lock_disable_pin_subtitle")', view)

    def test_change_pin_verification_authorizes_the_same_viewmodel(self):
        setup = code("odoo/UI/Settings/PinSetupView.swift")
        self.assertNotIn("SettingsViewModel()", setup, "PinSetupView must not own a second SettingsViewModel")
        self.assertIn("verifyCurrentPin(pin)", setup)
        view = code("odoo/UI/Settings/SettingsView.swift")
        self.assertIn("verifyCurrentPin: { viewModel.authorizePinChange(verifyingCurrentPin: $0) }", view)
        self.assertIn(".sheet(isPresented: $showPinSetup, onDismiss: { viewModel.cancelPinChange() })", view)

    def test_viewmodel_has_no_unverified_pin_check_left(self):
        vm = code("odoo/UI/Settings/SettingsViewModel.swift")
        self.assertNotIn("func verifyPin(", vm, "a bare Bool check bypasses the one-time authorization")


if __name__ == "__main__":
    unittest.main()
