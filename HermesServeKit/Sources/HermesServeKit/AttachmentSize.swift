import Foundation

/// How an attachment's size and an upload cap are written on screen.
///
/// Binary units, because the caps are configured in them: the file cap is 64 × 1024 × 1024 bytes, which the decimal file style printed as "67.1 MB", while the image cap printed as "25 MB". Writing a size and the cap it is checked against the same way is what makes "That file is 66.8 MB; the upload cap is 64 MB" an honest comparison.
public enum AttachmentSize {
    public static func text(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// The refusal for a file over `limit`, in one unit system.
    public static func tooLargeMessage(bytes: Int, limit: Int) -> String {
        "That file is \(text(bytes)); the upload cap is \(text(limit))."
    }
}
