//
//  AvatarPadding.swift
//  Construct Messenger
//
//  Every avatar is uploaded at one size, so the copies a profile sends to different contacts
//  cannot be told apart — or matched to each other — by their length (TODO 144).
//
//  The JPEG is followed by zero bytes up to the size. Decoders stop at the end-of-image marker
//  and read past nothing, so a receiver of any version shows it as before; the bytes are inside
//  the media encryption, so the server sees only the length, which is now the same for everyone.
//

import Foundation

enum AvatarPadding {
    /// The size of every avatar on the wire: the largest one `ImageHelper.prepareAvatarImage`
    /// produces on iOS. Anything larger (the macOS encoder sets no limit) goes to the next
    /// multiple, which is rarer and still says only "large".
    static let size = ImageHelper.maxAvatarFileSize

    static func padded(_ jpeg: Data) -> Data {
        let target = max(size, (jpeg.count + size - 1) / size * size)
        guard jpeg.count < target else { return jpeg }
        return jpeg + Data(count: target - jpeg.count)
    }
}
