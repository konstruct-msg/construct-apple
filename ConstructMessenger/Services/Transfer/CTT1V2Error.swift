//
//  CTT1V2Error.swift
//  Construct Messenger
//

import Foundation

enum CTT1V2Error: Error, Equatable {
    case malformed
    case v1RefusedForHistory
    case identityMismatch
    case kemKeyIdMismatch
    case qrPinMismatch
    case qrPinAbsent
    case noHybridKey
    case signatureInvalid
}
