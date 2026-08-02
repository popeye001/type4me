import Cocoa
import XCTest
@testable import Type4Me

final class HotkeyConflictTests: XCTestCase {

    func testModifierOnlyHotkeyDetectsPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 58,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testModifierOnlyHotkeyDetectsRegularKeyPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testFnModifierOnlyHotkeyDetectsRegularKeyPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 63,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }

    func testFnModifierOnlyHotkeyDetectsModifierComboPrefixConflict() {
        XCTAssertTrue(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 63,
                modifiers: 0,
                otherKeyCode: 56,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }

    func testLongerModifierBindingIsNotPrefixOfShorterRegularCombo() {
        XCTAssertFalse(
            ModeBinding.modifierBindingIsPrefix(
                modifierKeyCode: 58,
                modifierModifiers: CGEventFlags.maskControl.rawValue,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testMouseAndMediaKeysAreNotPrefixConflicts() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: ModeBinding.mouseKeyCode(for: 2),
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: ModeBinding.mediaKeyCode(for: 16),
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testRegularKeyWithoutModifiersIsNotPrefixConflict() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: 0
            )
        )
    }

    func testDifferentSingleModifiersAreNotPrefixConflicts() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: 0,
                otherKeyCode: 55,
                otherModifiers: 0
            )
        )
    }

    func testExactDuplicateModifierCombosAreNotPrefixConflicts() {
        XCTAssertFalse(
            ModeBinding.hasModifierPrefixConflict(
                keyCode: 59,
                modifiers: CGEventFlags.maskAlternate.rawValue,
                otherKeyCode: 58,
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )
    }

    func testFnModifierIsPreservedForRegularKeyCombos() {
        let flags = ModeBinding.normalizedModifierFlags(
            CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags.function.rawValue))
        )

        XCTAssertTrue(flags.contains(CGEventFlags.maskSecondaryFn))
    }

    func testSyntheticFnModifierIsIgnoredForFunctionKeys() {
        let flags = ModeBinding.normalizedModifierFlags(
            CGEventFlags.maskSecondaryFn,
            forKeyCode: 111
        )

        XCTAssertFalse(flags.contains(CGEventFlags.maskSecondaryFn))
        XCTAssertTrue(flags.isEmpty)
    }

    func testStoredFnModifierIsIgnoredForFunctionKeyBindings() {
        let flags = ModeBinding.normalizedModifierFlags(
            CGEventFlags(rawValue: UInt64(NSEvent.ModifierFlags.function.rawValue)),
            forKeyCode: 111
        )

        XCTAssertTrue(flags.isEmpty)
    }

    func testRecorderStripsSyntheticFnFromF12Capture() {
        let flags = HotkeyRecorderView.sanitizedModifierFlags(
            [.function],
            forKeyCode: 111
        )

        XCTAssertFalse(flags.contains(.function))
        XCTAssertTrue(flags.isEmpty)
    }

    func testRecorderPreservesFnForRegularKeyCapture() {
        let flags = HotkeyRecorderView.sanitizedModifierFlags(
            [.function],
            forKeyCode: 49
        )

        XCTAssertTrue(flags.contains(.function))
    }

    func testFunctionKeyBindingsIgnoreSyntheticFnForDuplicateChecks() {
        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 111,
                modifiers: 0,
                otherKeyCode: 111,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )

        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 111,
                modifiers: CGEventFlags.maskControl.rawValue,
                otherKeyCode: 111,
                otherModifiers: CGEventFlags.maskControl.union(.maskSecondaryFn).rawValue
            )
        )
    }

    func testRegularKeyBindingsStillDistinguishFnCombos() {
        XCTAssertFalse(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: 49,
                modifiers: 0,
                otherKeyCode: 49,
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }

    func testMouseAndMediaKeyDuplicateChecksIgnoreStoredModifierNoise() {
        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: ModeBinding.mouseKeyCode(for: 2),
                modifiers: 0,
                otherKeyCode: ModeBinding.mouseKeyCode(for: 2),
                otherModifiers: CGEventFlags.maskControl.rawValue
            )
        )

        XCTAssertTrue(
            ModeBinding.hotkeysAreEquivalent(
                keyCode: ModeBinding.mediaKeyCode(for: 16),
                modifiers: 0,
                otherKeyCode: ModeBinding.mediaKeyCode(for: 16),
                otherModifiers: CGEventFlags.maskSecondaryFn.rawValue
            )
        )
    }
}
