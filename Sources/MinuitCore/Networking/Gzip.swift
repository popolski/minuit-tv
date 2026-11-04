import Foundation

/// En-tête gzip (RFC 1952) : les guides XMLTV publics sont souvent servis en `.xml.gz`.
/// Le cœur repère le flux DEFLATE ; la décompression elle-même est faite par la plateforme.
public enum GzipContainer {
    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 18 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Plage du flux DEFLATE brut (en-tête et champs optionnels sautés, pied de 8 octets exclu).
    public static func deflateRange(_ data: Data) -> Range<Int>? {
        guard isGzip(data), data[data.startIndex + 2] == 8 else { return nil }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var p = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard p + 2 <= bytes.count else { return nil }
            p += 2 + Int(bytes[p]) + Int(bytes[p + 1]) << 8
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {   // FNAME, FCOMMENT
            while p < bytes.count, bytes[p] != 0 { p += 1 }
            p += 1
        }
        if flags & 0x02 != 0 { p += 2 }              // FHCRC
        let end = bytes.count - 8
        return p < end ? p..<end : nil
    }
}
