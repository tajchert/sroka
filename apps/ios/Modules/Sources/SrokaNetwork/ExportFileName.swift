import Foundation
import SrokaCore

/// File name for an export, from a `Content-Disposition` header, reduced to a bare name. Falls back to
/// `sroka-export-YYYY-MM-DD.<ext>`. Port of Android's `exportFileName`.
func exportFileName(header: String?, format: ExportFormat, today: Date, calendar: Calendar = .current) -> String {
    if let header, let raw = extractFileName(from: header) {
        let bare = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let clean = bare.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty, clean != ".", clean != ".." { return clean }
    }
    let parts = calendar.dateComponents([.year, .month, .day], from: today)
    let stamp = String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    return "sroka-export-\(stamp).\(format.fileExtension)"
}

private func extractFileName(from header: String) -> String? {
    // RFC 5987 `filename*=UTF-8''…` wins over the plain `filename=`.
    if let match = header.firstMatch(of: /(?i)filename\*\s*=\s*UTF-8''([^;]+)/) {
        let encoded = String(match.1).replacingOccurrences(of: "+", with: "%2B")
        if let decoded = encoded.removingPercentEncoding { return decoded }
    }
    if let match = header.firstMatch(of: /(?i)filename\s*=\s*(?:"([^"]*)"|([^;\s]+))/) {
        if let quoted = match.1, !quoted.isEmpty { return String(quoted) }
        if let bare = match.2 { return String(bare) }
        return ""
    }
    return nil
}
