import SrokaCore
import SrokaDatabase
import SrokaNetwork

extension ItemDto {
    /// The local row for a pulled item (Android `sync/ItemMapping.kt`). `ItemDao.upsert` keeps the
    /// existing FTS rowid; the resync mark is cleared because the server just confirmed the item.
    func toRecord() -> ItemRecord {
        ItemRecord(
            id: id,
            url: url,
            canonicalUrl: canonicalUrl ?? UrlNormalizer.normalize(url) ?? url,
            title: title,
            excerpt: excerpt,
            siteName: siteName,
            author: author,
            lang: lang,
            leadImageKey: leadImageKey,
            wordCount: wordCount,
            readingMinutes: readingMinutes,
            contentId: contentId,
            contentPrivate: contentPrivate,
            parseStatus: parseStatusFromWire(parseStatus, contentId: contentId),
            parseError: parseError,
            status: statusValue,
            isFavorite: isFavorite,
            progress: progress.isNaN ? 0 : min(1, max(0, progress)),
            progressAnchor: progressAnchor,
            savedAt: savedAt,
            archivedAt: archivedAt,
            lastReadAt: lastReadAt,
            source: source,
            serverSeq: seq,
            resyncMark: 0,
            kind: kindValue,
            fileName: fileName,
            fileSize: fileSize
        )
    }
}

/// Unknown future values: readable content counts as ok, otherwise pending.
func parseStatusFromWire(_ value: String, contentId: String?) -> ParseStatus {
    ParseStatus(rawValue: value) ?? (contentId != nil ? .ok : .pending)
}
