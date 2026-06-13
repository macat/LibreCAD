//
//  StrokeFontProvider.swift
//  CADEngine
//
//  Loads and caches `.lff` stroke fonts by name, and exposes a closure matching
//  the reserved `ResolveContext.fontProvider` hook shape `((String) -> StrokeFont?)`
//  (ADR-004). The Text-entity resolve owner will, when it lands, read a DXF text
//  style's font name and call this provider to obtain the strokes.
//
//  Naming: a font is keyed by its *base name* (lowercased, no extension), e.g.
//  "standard" for "standard.lff" — matching how LibreCAD resolves a style's
//  font name against its font search paths (RS_Font::loadFont).
//
//  GPLv2-or-later (LibreCAD derivative).
//
//  Copyright (C) 2026 LibreCAD macOS contributors.
//  Copyright (C) 2010 R. van Twisk (librecad@rvt.dds.nl).
//

import Foundation

/// Loads `.lff` fonts from disk and caches the parsed `StrokeFont`s by base
/// name. Thread-safe (an internal lock guards the cache) so it can be shared and
/// its `provider` closure can be `@Sendable`.
///
/// ## Wiring into `ResolveContext.fontProvider`
/// The reserved hook (commented in `Resolve.swift`) is:
/// ```swift
/// var fontProvider: ((String) -> StrokeFont?)? = nil   // Text owner (.lff, ADR-004)
/// ```
/// This provider supplies exactly that closure via `makeProvider()`:
/// ```swift
/// let provider = StrokeFontProvider()
/// provider.registerSearchDirectory(fontsDir)
/// ctx.fontProvider = provider.makeProvider()   // ((String) -> StrokeFont?)
/// ```
/// The Text owner only needs to call `ctx.fontProvider?(styleFontName)`.
public final class StrokeFontProvider: @unchecked Sendable {

    /// Directories searched (in order) for `<name>.lff` when a font isn't
    /// registered by explicit URL.
    private var searchDirectories: [URL] = []
    /// Explicit name → URL registrations (take precedence over search dirs).
    private var registeredURLs: [String: URL] = [:]
    /// Parsed-font cache keyed by base name. `nil` value caches a *miss* so a
    /// repeated lookup of an absent font doesn't re-hit the disk.
    private var cache: [String: StrokeFont?] = [:]
    private let lock = NSLock()

    public init() {}

    // MARK: - Registration

    /// Adds a directory to search for `<name>.lff` files.
    public func registerSearchDirectory(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        searchDirectories.append(url)
    }

    /// Registers a specific `.lff` file under a name (defaults to the file's
    /// base name). Clears any cached result for that name.
    @discardableResult
    public func registerFont(at url: URL, name: String? = nil) -> String {
        let key = Self.normalize(name ?? url.deletingPathExtension().lastPathComponent)
        lock.lock(); defer { lock.unlock() }
        registeredURLs[key] = url
        cache[key] = nil   // invalidate (will re-parse on next access)
        cache.removeValue(forKey: key)
        return key
    }

    // MARK: - Lookup

    /// Returns the parsed font for `name`, loading + caching it on first access.
    /// `name` may be a base name ("standard"), a file name ("standard.lff"), or
    /// an absolute/relative path to a `.lff` file. Returns `nil` if not found or
    /// unparseable.
    public func font(named name: String) -> StrokeFont? {
        // Treat an existing .lff path as a direct load (still cached by base name).
        if name.lowercased().hasSuffix(".lff"),
           FileManager.default.fileExists(atPath: name) {
            return loadAndCache(url: URL(fileURLWithPath: name),
                                key: Self.normalize(URL(fileURLWithPath: name)
                                    .deletingPathExtension().lastPathComponent))
        }

        let key = Self.normalize(name)

        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }   // hit (incl. cached miss)
        let registered = registeredURLs[key]
        let dirs = searchDirectories
        lock.unlock()

        // Resolve a URL: explicit registration first, then search dirs.
        let url: URL?
        if let registered {
            url = registered
        } else {
            url = dirs.lazy
                .map { $0.appendingPathComponent("\(key).lff") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }

        guard let url else {
            lock.lock(); cache[key] = .some(nil); lock.unlock()   // cache the miss
            return nil
        }
        return loadAndCache(url: url, key: key)
    }

    private func loadAndCache(url: URL, key: String) -> StrokeFont? {
        // Parse outside the lock (I/O + parse can be slow); store under the lock.
        let parsed = try? LFFParser.load(contentsOf: url)
        lock.lock(); cache[key] = .some(parsed); lock.unlock()
        return parsed
    }

    /// Drops all cached fonts (keeps registrations / search dirs).
    public func clearCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
    }

    // MARK: - ResolveContext.fontProvider adapter

    /// A `@Sendable` closure of the reserved `((String) -> StrokeFont?)` shape,
    /// ready to assign to `ResolveContext.fontProvider` once the Text owner adds
    /// that field. Captures `self` (thread-safe) so all callers share the cache.
    public func makeProvider() -> @Sendable (String) -> StrokeFont? {
        { [self] name in self.font(named: name) }
    }

    // MARK: - Helpers

    /// Normalizes a font name to a cache/search key: drop a `.lff` extension,
    /// lowercase. (LibreCAD compares font base names case-insensitively.)
    static func normalize(_ name: String) -> String {
        var n = name
        if n.lowercased().hasSuffix(".lff") { n = String(n.dropLast(4)) }
        // Keep only the last path component so a path resolves to its base name.
        if let slash = n.lastIndex(of: "/") { n = String(n[n.index(after: slash)...]) }
        return n.lowercased()
    }
}
