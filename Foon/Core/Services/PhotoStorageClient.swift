import Foundation
import Supabase

/// Household photos in the private `household-photos` bucket. Upload only what
/// `PhotoPreparation.prepare` returns; show photos only through short-lived signed URLs.
struct PhotoStorageClient: Sendable {
    static let bucket = "household-photos"
    /// Long enough to load and cache an image, short enough that a shared link soon stops working.
    static let signedURLLifetime = 15 * 60

    /// Stores a prepared JPEG under the household's folder and returns its path (for `meals.photo_path`).
    var upload: @Sendable (_ householdID: UUID, _ preparedJPEG: Data) async throws -> String
    var signedURL: @Sendable (_ path: String) async throws -> URL
    var remove: @Sendable (_ path: String) async throws -> Void

    /// `<household id>/meals/<photo id>.jpg`, lowercase to match the storage policy's folder check.
    static func mealPhotoPath(householdID: UUID, photoID: UUID = UUID()) -> String {
        "\(householdID.uuidString.lowercased())/meals/\(photoID.uuidString.lowercased()).jpg"
    }

    /// Uploads a meal's new photo, points the meal at it, then deletes the photo it replaced. `pointMeal` returns the
    /// path the meal held before, read by the server, so a replacement made on another phone isn't left behind.
    func replace(
        householdID: UUID, preparedJPEG: Data,
        pointMeal: @Sendable (_ path: String) async throws -> String?
    ) async throws {
        let path = try await upload(householdID, preparedJPEG)
        let previous: String?
        do {
            previous = try await pointMeal(path)
        } catch LibraryClientError.notAllowed {
            // Only a refusal is sure to have changed nothing; after a lost reply the meal may already show the upload.
            try? await remove(path)
            throw LibraryClientError.notAllowed
        }
        // The meal shows the new photo either way, so a file that can't be deleted now doesn't fail the change.
        if let previous, previous != path { try? await remove(previous) }
    }
}

extension PhotoStorageClient {
    static func live(_ client: SupabaseClient) -> PhotoStorageClient {
        PhotoStorageClient(
            upload: { householdID, preparedJPEG in
                let path = mealPhotoPath(householdID: householdID)
                _ = try await client.storage.from(bucket)
                    .upload(path, data: preparedJPEG, options: FileOptions(contentType: "image/jpeg"))
                return path
            },
            signedURL: { path in
                try await client.storage.from(bucket).createSignedURL(path: path, expiresIn: signedURLLifetime)
            },
            remove: { path in
                _ = try await client.storage.from(bucket).remove(paths: [path])
            }
        )
    }
}
