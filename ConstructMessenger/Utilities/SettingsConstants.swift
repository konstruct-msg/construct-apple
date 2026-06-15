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
    static let recentLogContainerHeight: CGFloat = 340
    static let clearLogsRefreshDelay: TimeInterval = 0.3
}

enum DiagnosticsLayout {
    static let sectionHintSpacing: CGFloat = SettingsLayout.sectionHeaderSpacing
    static let disabledActionOpacity: Double = 0.4
    static let statusDotSize: CGFloat = 8
    static let recentLogFontSize: CGFloat = 10
    static let recentLogPadding: CGFloat = 8
}

enum NotificationsSettingsLayout {
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 12
    static let compactSectionSpacing: CGFloat = 0
    static let footerBottomPadding: CGFloat = 8
    static let sectionVerticalPadding: CGFloat = 20
    static let pushDetailSpacing: CGFloat = 4
}

enum NetworkSettingsLayout {
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 12
    static let compactRowVerticalPadding: CGFloat = 10
    static let relayRowVerticalPadding: CGFloat = 8
    static let compactSectionSpacing: CGFloat = 0
    static let sectionVerticalPadding: CGFloat = 20
    static let footerVerticalPadding: CGFloat = 12
    static let statusRowSpacing: CGFloat = 12
    static let statusDetailSpacing: CGFloat = 2
    static let transportBadgeHorizontalPadding: CGFloat = 5
    static let transportBadgeVerticalPadding: CGFloat = 2
    static let transportBadgeCornerRadius: CGFloat = 4
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
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 12
    static let toggleRowSpacing: CGFloat = 12
    static let warningSpacing: CGFloat = 4
    static let sectionVerticalPadding: CGFloat = 20
    static let footerBottomPadding: CGFloat = 8
    static let sliderSectionSpacing: CGFloat = 12
    static let tickLabelFontSize: CGFloat = 10
    static let tickLabelMinimumScale: CGFloat = 0.7
    static let trackMarkSpacing: CGFloat = 4
    static let trackMarkWidth: CGFloat = 1
    static let trackMinorMarkHeight: CGFloat = 5
    static let trackMajorMarkHeight: CGFloat = 8
    static let disabledRowOpacity: Double = 0.5
}

enum BackgroundFetchSettingsConfig {
    static let intervalStepMinutes: Int = 5
    static let intervalPresets: [Int] = [5, 15, 30, 60]
}

enum SecuritySettingsLayout {
    static let rowHorizontalPadding: CGFloat = 12
    static let rowVerticalPadding: CGFloat = 12
    static let compactRowVerticalPadding: CGFloat = 10
    static let rowContentSpacing: CGFloat = 10
    static let sectionVerticalPadding: CGFloat = 8
    static let hintTopPadding: CGFloat = 6
    static let hintBottomPadding: CGFloat = 10
    static let hintCompactTopPadding: CGFloat = 2
    static let hintDisabledOpacity: Double = 0.6
    static let lockStatusSpacing: CGFloat = 2
    static let recoveryStatusSpacing: CGFloat = 2
    static let separatorOpacity: Double = 0.4
}

enum KeyTransparencySettingsLayout {
    static let rowHorizontalPadding: CGFloat = 16
    static let rowVerticalPadding: CGFloat = 10
    static let hintHorizontalPadding: CGFloat = 12
    static let hintTopPadding: CGFloat = 2
    static let hintBottomPadding: CGFloat = 10
    static let statusTrailingPadding: CGFloat = 4
}

enum DevicesSettingsLayout {
    static let sectionSpacing: CGFloat = 6
    static let listSpacing: CGFloat = 20
    static let listVerticalPadding: CGFloat = 20
    static let rowContentSpacing: CGFloat = 12
    static let rowHorizontalPadding: CGFloat = 16
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
    static let profileRowSpacing: CGFloat = 12
    static let profileMetaSpacing: CGFloat = 3
    static let profileRowHorizontalPadding: CGFloat = 12
    static let profileRowVerticalPadding: CGFloat = 12
    static let recoveryBannerContentSpacing: CGFloat = 10
    static let recoveryBannerTextSpacing: CGFloat = 4
    static let recoveryBannerActionSpacing: CGFloat = 3
    static let recoveryBannerPadding: CGFloat = 12
    static let recoveryBannerCornerRadius: CGFloat = 10
    static let recoveryBannerStrokeWidth: CGFloat = 0.5
    static let recoveryBannerHorizontalPadding: CGFloat = 12
    static let recoveryBannerVerticalPadding: CGFloat = 8
    static let recoveryBannerIconSize: CGFloat = 15
    static let recoveryBannerChevronSize: CGFloat = 9
    static let recoveryBannerDismissIconSize: CGFloat = 11
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
    static let qrCodeErrorSpacing: CGFloat = 10
    static let qrCodeErrorHorizontalPadding: CGFloat = 16
    static let timerRowSpacing: CGFloat = 6
    static let expiredBlockSpacing: CGFloat = 14
    static let refreshButtonHorizontalPadding: CGFloat = 20
    static let refreshButtonVerticalPadding: CGFloat = 10
    static let refreshButtonStrokeOpacity: Double = 0.4
    static let refreshButtonStrokeWidth: CGFloat = 1
    static let idealWidth: CGFloat = 400
    static let idealHeight: CGFloat = 520
}

enum DeviceLinkQRLayout {
    static let rootSpacing: CGFloat = 0
    static let loadingSpacing: CGFloat = 12
    static let loadingIndicatorScale: CGFloat = 1.4
    static let contentSpacing: CGFloat = 24
    static let sectionHeaderSpacing: CGFloat = 6
    static let sectionHeaderHorizontalPadding: CGFloat = 20
    static let sectionHeaderTopPadding: CGFloat = 20
    static let instructionsHorizontalPadding: CGFloat = 24
    static let scanHintHorizontalPadding: CGFloat = 24
    static let scanHintBottomPadding: CGFloat = 32
    static let qrSize: CGFloat = 220
    static let qrPadding: CGFloat = 16
    static let qrBorderWidth: CGFloat = 1
    static let expiredStateSpacing: CGFloat = 16
    static let statusIconSize: CGFloat = 36
    static let actionButtonHorizontalPadding: CGFloat = 16
    static let actionButtonVerticalPadding: CGFloat = 10
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
