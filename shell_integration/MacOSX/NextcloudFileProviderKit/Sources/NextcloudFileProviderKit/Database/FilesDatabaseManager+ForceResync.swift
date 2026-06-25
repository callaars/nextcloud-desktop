//  SPDX-FileCopyrightText: 2026 Nextcloud GmbH and Nextcloud contributors
//  SPDX-License-Identifier: LGPL-3.0-or-later

@preconcurrency import FileProvider
import Foundation
import RealmSwift

public extension FilesDatabaseManager {
    ///
    /// Force a re-synchronisation of a directory and everything beneath it by
    /// invalidating the stored etags of the directory and all of its descendant
    /// directories.
    ///
    /// File Provider drives enumeration top-down and only re-reads a container's
    /// children when the container's stored etag differs from the server's (see
    /// ``depth1ReadUpdateItemMetadatas(account:serverUrl:updatedMetadatas:keepExistingDownloadState:)``
    /// and `Enumerator.enumerateChanges`). Blanking the etag of the target
    /// directory and every descendant directory therefore forces the framework
    /// to re-`PROPFIND` every level and re-validate every item against the server
    /// on the next enumeration — the File Provider analogue of the classic sync
    /// engine's `SyncJournalDb::wipeSyncStateForPathAndBelow`. Only directory
    /// etags gate child re-enumeration, so invalidating them is sufficient to
    /// force a full deep re-read; unchanged files re-validate by etag and are not
    /// needlessly re-downloaded.
    ///
    /// Directories with a pending upload (`status >= Status.inUpload`) and
    /// local-origin lock files are left untouched, matching the guards in
    /// ``deleteDirectoryAndSubdirectoriesMetadata(ocId:)``.
    ///
    /// - Parameter ocId: The `ocId` of the directory whose sync state should be reset.
    /// - Returns: The number of directory metadatas whose etag was invalidated,
    ///   or `nil` if no directory with the given `ocId` exists.
    ///
    @discardableResult
    func resetSyncStateForDirectoryAndChildren(ocId: String) -> Int? {
        guard let directoryMetadata = itemMetadatas
            .where({ $0.ocId == ocId && $0.directory })
            .first
        else {
            logger.error("Could not find directory metadata for ocId. Not resetting sync state.", [.item: ocId])
            return nil
        }

        let directoryAccount = directoryMetadata.account
        let directoryUrlPath = directoryMetadata.serverUrl + "/" + directoryMetadata.fileName

        // The target directory plus every descendant directory. A descendant's
        // parent path either equals the target's full path (immediate children)
        // or is prefixed by it (deeper descendants); the target itself is matched
        // by ocId.
        let directories = itemMetadatas.where {
            $0.account == directoryAccount &&
                $0.directory == true &&
                ($0.ocId == ocId ||
                    $0.serverUrl == directoryUrlPath ||
                    $0.serverUrl.starts(with: directoryUrlPath + "/"))
        }

        let database = ncDatabase()
        var resetCount = 0
        do {
            try database.write {
                for directory in directories {
                    if directory.status >= Status.inUpload.rawValue {
                        logger.info("Skipping etag reset of directory with pending upload.", [.item: directory.ocId])
                        continue
                    }
                    if directory.isLockFileOfLocalOrigin {
                        continue
                    }
                    directory.etag = ""
                    resetCount += 1
                }
            }
        } catch {
            logger.error("Failure resetting sync state for directory and children.", [.error: error, .item: ocId, .url: directoryUrlPath])
            return nil
        }

        logger.debug("Reset sync state for directory and children.", [.item: ocId, .url: directoryUrlPath])
        return resetCount
    }
}
