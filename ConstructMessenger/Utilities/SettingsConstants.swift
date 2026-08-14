//
//  SettingsConstants.swift
//  Construct Messenger
//
//  Centralized constants for Settings UI screens.
//

import Foundation
import SwiftUI

enum SettingsLayout {
    static let sectionSpacing: CGFloat = 20
    static let sectionHeaderSpacing: CGFloat = 6
    static let rowContentSpacing: CGFloat = 14
    static let rowHorizontalPadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 14
    static let rowIconMinWidth: CGFloat = 22
    static let rowDividerIndent: CGFloat = 52
    static let screenVerticalPadding: CGFloat = 20
    static let footerHorizontalPadding: CGFloat = 20
}

enum AppearanceSettingsConfig {
    static let availabilityBadgeHorizontalPadding: CGFloat = 6
    static let availabilityBadgeVerticalPadding: CGFloat = 2
    static let availabilityBadgeStrokeWidth: CGFloat = 1
}

enum AppearanceSettingsLayout {
    static let themeRowContentSpacing: CGFloat = SettingsLayout.rowContentSpacing
    static let themeRowHorizontalPadding: CGFloat = SettingsLayout.rowHorizontalPadding
    static let themeRowVerticalPadding: CGFloat = SettingsLayout.rowVerticalPadding
}

enum DataStorageSettingsLayout {
    static let rowContentSpacing: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 16
    static let usageRowTopPadding: CGFloat = 13
    static let usageRowBottomPaddingWithQuota: CGFloat = 10
    static let usageRowBottomPaddingWithoutQuota: CGFloat = 13
    static let usageBarHeight: CGFloat = 5
    static let usageBarSpacing: CGFloat = 5
    static let quotaSectionSpacing: CGFloat = 12
    static let quotaTickFontSize: CGFloat = 9
    static let quotaTickMinimumScale: CGFloat = 0.7
    static let autoEvictionCheckIconSize: CGFloat = 17
    static let footerTopPadding: CGFloat = 6
    static let screenBottomPadding: CGFloat = 32
    static let usageIconFontSize: CGFloat = 16
    static let sectionTitleTracking: CGFloat = 1
    static let usageFractionAnimationDuration: TimeInterval = 0.4
    static let clearActionDisabledOpacity: Double = 0.5
}

enum DataStorageSettingsConfig {
    static let quarterGBInBytes = 268_435_456
    static let halfGBInBytes = 536_870_912
    static let usageWarningThreshold: Double = 0.85
    static let oneGBInBytes = 1_073_741_824
    static let twoGBInBytes = 2_147_483_648
    static let fiveGBInBytes = 5_368_709_120
    static let evictAfterOneWeekDays: Int = 7
    static let evictAfterOneMonthDays: Int = 30
    static let evictAfterThreeMonthsDays: Int = 90
}

enum DiagnosticsConfig {
    static let apnsTokenPreviewPrefixLength: Int = 8
    static let recentLogLineLimit: Int = 200
    /// Tail window for the recent-log preview. 256 KB holds ~200 lines at any realistic width;
    /// the point is that it is a constant, so the read cost no longer scales with the log file.
    static let recentLogTailBytes: Int = 256 * 1024
    static let recentLogContainerHeight: CGFloat = 340
    // clearLogsRefreshDelay removed 2026-08-04: `clearLogs` now reports completion, so there is
    // nothing left to guess a duration for. A constant with no consumer is a defect (AGENTS.md).
}

enum DiagnosticsLayout {
    static let sectionHintSpacing: CGFloat = SettingsLayout.sectionHeaderSpacing
    static let disabledActionOpacity: Double = 0.4
    static let statusDotSize: CGFloat = 8
    static let recentLogFontSize: CGFloat = 10
    static let recentLogPadding: CGFloat = 8
}

enum NotificationsSettingsLayout {
    static let rowHorizontalPadding: CGFloat = CTLayout.edgePad
    static let rowVerticalPadding: CGFloat = CTLayout.edgePad
    static let compactSectionSpacing: CGFloat = 0
    static let footerBottomPadding: CGFloat = CTLayout.inlinePad
    static let sectionVerticalPadding: CGFloat = 20
    static let pushDetailSpacing: CGFloat = 4
}

enum NetworkSettingsLayout {
    static let rowHorizontalPadding: CGFloat = CTLayout.edgePad
    static let rowVerticalPadding: CGFloat = CTLayout.edgePad
    static let compactRowVerticalPadding: CGFloat = CTLayout.chromeGap
    static let relayRowVerticalPadding: CGFloat = CTLayout.inlinePad
    static let compactSectionSpacing: CGFloat = 0
    static let sectionVerticalPadding: CGFloat = 20
    static let footerVerticalPadding: CGFloat = CTLayout.edgePad
    static let statusRowSpacing: CGFloat = CTLayout.edgePad
    static let statusDetailSpacing: CGFloat = 2
    static let transportBadgeHorizontalPadding: CGFloat = 5
    static let transportBadgeVerticalPadding: CGFloat = 2
    /// Tiny transport chip — maps to badge scale (was ad-hoc 4).
    static let transportBadgeCornerRadius: CGFloat = CTRadius.badge
    static let transportBadgeStrokeWidth: CGFloat = 0.5
    static let transportBadgeStrokeOpacity: Double = 0.4
    static let relayBadgeFontSize: CGFloat = 10
    static let statusDisabledOpacity: Double = 0.5
    static let errorMonospacedFontSize: CGFloat = 11
    static let relayAddressFontSize: CGFloat = 13
}

enum NetworkSettingsLabels {
    static let quic = "QUIC"
    static let h2 = "H2"
    static let tls = "TLS"
    static let obfs4 = "obfs4"
}

enum BackgroundFetchSettingsLayout {
    static let rowHorizontalPadding: CGFloat = CTLayout.edgePad
    static let rowVerticalPadding: CGFloat = CTLayout.edgePad
    static let toggleRowSpacing: CGFloat = CTLayout.edgePad
    static let warningSpacing: CGFloat = 4
    static let sectionVerticalPadding: CGFloat = 20
    static let footerBottomPadding: CGFloat = CTLayout.inlinePad
    static let sliderSectionSpacing: CGFloat = CTLayout.edgePad
    static let tickLabelFontSize: CGFloat = 10
    static let tickLabelMinimumScale: CGFloat = 0.7
    static let trackMarkSpacing: CGFloat = 4
    static let trackMarkWidth: CGFloat = 1
    static let trackMinorMarkHeight: CGFloat = 5
    static let trackMajorMarkHeight: CGFloat = CTLayout.inlinePad
    static let disabledRowOpacity: Double = 0.5
}

enum BackgroundFetchSettingsConfig {
    static let intervalStepMinutes: Int = 5
    static let intervalPresets: [Int] = [5, 15, 30, 60]
}

enum SecuritySettingsLayout {
    static let rowHorizontalPadding: CGFloat = CTLayout.edgePad
    static let rowVerticalPadding: CGFloat = CTLayout.edgePad
    static let compactRowVerticalPadding: CGFloat = CTLayout.chromeGap
    static let rowContentSpacing: CGFloat = CTLayout.chromeGap
    static let sectionVerticalPadding: CGFloat = CTLayout.inlinePad
    static let hintTopPadding: CGFloat = 6
    static let hintBottomPadding: CGFloat = CTLayout.chromeGap
    static let hintCompactTopPadding: CGFloat = 2
    static let hintDisabledOpacity: Double = 0.6
    static let lockStatusSpacing: CGFloat = 2
    static let recoveryStatusSpacing: CGFloat = 2
    static let separatorOpacity: Double = 0.4
}

enum KeyTransparencySettingsLayout {
    static let rowHorizontalPadding: CGFloat = CTLayout.sectionGap
    static let rowVerticalPadding: CGFloat = CTLayout.chromeGap
    static let hintHorizontalPadding: CGFloat = CTLayout.edgePad
    static let hintTopPadding: CGFloat = 2
    static let hintBottomPadding: CGFloat = CTLayout.chromeGap
    static let statusTrailingPadding: CGFloat = 4
}

enum DevicesSettingsLayout {
    static let sectionSpacing: CGFloat = 6
    static let listSpacing: CGFloat = 20
    static let listVerticalPadding: CGFloat = 20
    static let rowContentSpacing: CGFloat = CTLayout.edgePad
    static let rowHorizontalPadding: CGFloat = CTLayout.sectionGap
    static let rowVerticalPadding: CGFloat = 14
    static let hintHorizontalPadding: CGFloat = 20
    static let deviceMetaSpacing: CGFloat = 2
    static let currentStatusSpacing: CGFloat = 4
    static let currentStatusDotSize: CGFloat = 7
    static let dividerIndent: CGFloat = 52
}

enum SettingsRootLayout {
    static let rootSpacing: CGFloat = 20
    static let listSpacing: CGFloat = 30
    static let listBottomPadding: CGFloat = 32
    static let profileRowSpacing: CGFloat = CTLayout.edgePad
    static let profileMetaSpacing: CGFloat = 3
    static let profileRowHorizontalPadding: CGFloat = CTLayout.edgePad
    static let profileRowVerticalPadding: CGFloat = CTLayout.edgePad
    static let recoveryBannerContentSpacing: CGFloat = CTLayout.chromeGap
    static let recoveryBannerTextSpacing: CGFloat = 4
    static let recoveryBannerActionSpacing: CGFloat = 3
    static let recoveryBannerPadding: CGFloat = CTLayout.edgePad
    /// Interactive banner surface — control radius family.
    static let recoveryBannerCornerRadius: CGFloat = CTRadius.control
    static let recoveryBannerStrokeWidth: CGFloat = 0.5
    static let recoveryBannerHorizontalPadding: CGFloat = CTLayout.edgePad
    static let recoveryBannerVerticalPadding: CGFloat = CTLayout.inlinePad
    static let recoveryBannerIconSize: CGFloat = 15
    static let recoveryBannerChevronSize: CGFloat = 9
    static let recoveryBannerDismissIconSize: CGFloat = 11
}

/// Compact invite card on Settings root (QR | Copy + several).
enum SettingsShareLayout {
    static let actionMinHeight: CGFloat = CTLayout.hitTarget
    static let actionIconSize: CGFloat = 16
    static let actionSpacing: CGFloat = CTLayout.inlinePad
    static let dividerWidth: CGFloat = 0.5
    static let dividerVerticalPadding: CGFloat = CTLayout.inlinePad
    static let captionHorizontalPadding: CGFloat = CTLayout.edgePad
    static let captionVerticalPadding: CGFloat = CTLayout.inlinePad
    static let captionLinkSpacing: CGFloat = 4
    static let captionChevronSize: CGFloat = 8
    /// Debounce only — each tap mints a new one-time link. A multi-second disable
    /// made "copy again for the next person" feel broken.
    static let copyDebounce: TimeInterval = 0.3
    static let copyFlashDuration: TimeInterval = 2
}

enum ContactQRCodeLayout {
    static let contentSpacing: CGFloat = 0
    static let identityHeaderSpacing: CGFloat = 6
    static let identityVerticalPadding: CGFloat = 20
    static let qrBlockSpacing: CGFloat = 20
    static let qrBlockVerticalPadding: CGFloat = 28
    static let footerHorizontalPadding: CGFloat = 20
    static let footerVerticalPadding: CGFloat = 14
    static let qrCodeBorderWidth: CGFloat = 1
    /// QR frames and outline buttons use form/card radius.
    static let cornerRadius: CGFloat = CTRadius.card
    static let qrCodeErrorSpacing: CGFloat = CTLayout.chromeGap
    static let qrCodeErrorHorizontalPadding: CGFloat = CTLayout.sectionGap
    static let timerRowSpacing: CGFloat = 6
    static let timerIconSize: CGFloat = 11
    static let refreshButtonHorizontalPadding: CGFloat = 20
    static let refreshButtonVerticalPadding: CGFloat = CTLayout.chromeGap
    static let refreshButtonStrokeOpacity: Double = 0.4
    static let refreshButtonStrokeWidth: CGFloat = 1
    static let idealWidth: CGFloat = 400
    static let idealHeight: CGFloat = 520
}

enum DeviceLinkQRLayout {
    static let rootSpacing: CGFloat = 0
    static let loadingSpacing: CGFloat = CTLayout.edgePad
    static let loadingIndicatorScale: CGFloat = 1.4
    static let contentSpacing: CGFloat = 24
    static let sectionHeaderSpacing: CGFloat = 6
    static let sectionHeaderHorizontalPadding: CGFloat = 20
    static let sectionHeaderTopPadding: CGFloat = 20
    static let instructionsHorizontalPadding: CGFloat = 24
    static let scanHintHorizontalPadding: CGFloat = 24
    static let scanHintBottomPadding: CGFloat = 32
    static let qrSize: CGFloat = 220
    static let qrPadding: CGFloat = CTLayout.sectionGap
    static let qrBorderWidth: CGFloat = 1
    static let cornerRadius: CGFloat = CTRadius.card
    static let expiredStateSpacing: CGFloat = CTLayout.sectionGap
    static let statusIconSize: CGFloat = 36
    static let actionButtonHorizontalPadding: CGFloat = CTLayout.sectionGap
    static let actionButtonVerticalPadding: CGFloat = CTLayout.chromeGap
    static let actionButtonStrokeWidth: CGFloat = 0.5
    static let errorMessageHorizontalPadding: CGFloat = 24
}

enum AccountSettingsLayout {
    static let sectionDisabledOpacity: Double = 0.5
    static let footerHorizontalPadding: CGFloat = 20
    static let footerVerticalPadding: CGFloat = 12
    static let footerTextOpacity: Double = 0.6
    static let postAvatarPickerDelay: TimeInterval = 0.35

    static let avatarSectionSpacing: CGFloat = 14
    static let avatarSectionVerticalPadding: CGFloat = 28
    static let avatarSectionEditingOpacity: Double = 0.55

    static let sectionHintHorizontalPadding: CGFloat = 20
    static let sectionHintBottomPadding: CGFloat = 8

    static let discoverableRowSpacing: CGFloat = 8
    static let discoverableRowHorizontalPadding: CGFloat = 16
    static let discoverableRowVerticalPadding: CGFloat = 8

    static let dividerHeight: CGFloat = 1
    static let dividerRegularOpacity: Double = 0.5
    static let dividerRowOpacity: Double = 0.35
    static let dividerHorizontalPadding: CGFloat = 20

    static let sectionHeaderSpacing: CGFloat = 6
    static let sectionHeaderHorizontalPadding: CGFloat = 20
    static let sectionHeaderVerticalPadding: CGFloat = 10
    static let sectionHeaderTracking: CGFloat = 2

    static let rowHorizontalPadding: CGFloat = 20
    static let rowVerticalPadding: CGFloat = 14

    static let inlineStatusSpacing: CGFloat = 8
    static let inlineStatusAccentOpacity: Double = 0.6
    static let dangerPrimaryOpacity: Double = 0.85
    static let dangerSecondaryOpacity: Double = 0.7

    static let editableFieldMaxWidth: CGFloat = 190
    static let editableSavingIndicatorScale: CGFloat = 0.8
    static let fingerprintCopiedFlashDuration: TimeInterval = 1.5
}

enum DeleteAccountSheetLayout {
    static let countdownStartValue: Int = 7
    static let rootSpacing: CGFloat = 0
    static let dragIndicatorWidth: CGFloat = 36
    static let dragIndicatorHeight: CGFloat = 4
    static let dragIndicatorTopPadding: CGFloat = 12
    static let dragIndicatorBottomPadding: CGFloat = 24
    static let titleBottomPadding: CGFloat = 8
    static let messageHorizontalPadding: CGFloat = 32
    static let messageBottomPadding: CGFloat = 32
    static let countdownBottomPadding: CGFloat = 28
    static let localDeleteActionBottomPadding: CGFloat = 16
    static let actionsSpacing: CGFloat = 12
    static let actionButtonHeight: CGFloat = 50
    static let actionsHorizontalPadding: CGFloat = 24
    static let actionsBottomPadding: CGFloat = 36
    static let deleteButtonDisabledOpacity: Double = 0.4
    static let deleteButtonIdleFillOpacity: Double = 0.08
    static let deleteButtonActiveFillOpacity: Double = 0.15
    static let deleteButtonIdleStrokeOpacity: Double = 0.2
    static let deleteButtonActiveStrokeOpacity: Double = 0.5
    static let deleteButtonStrokeWidth: CGFloat = 1
    static let deleteButtonAnimationDuration: TimeInterval = 0.25
    static let localDeleteWarningOpacity: Double = 0.75
    static let countdownStepSeconds: TimeInterval = 1
}
