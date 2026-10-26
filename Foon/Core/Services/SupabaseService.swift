import Supabase

/// Owns the app's single `SupabaseClient`. Feature services take this (or its client) rather than building their own.
actor SupabaseService {
    static let shared: SupabaseService = {
        do {
            return SupabaseService(config: try SupabaseConfig.fromMainBundle())
        } catch {
            fatalError("Supabase is not configured (\(error)). See README → Local Supabase.")
        }
    }()

    nonisolated let client: SupabaseClient

    init(config: SupabaseConfig) {
        client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey,
            // Opt into the next major's behavior now so the session-restore path never changes under us.
            options: SupabaseClientOptions(auth: .init(emitLocalSessionAsInitialSession: true))
        )
    }
}
