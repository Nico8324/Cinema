/*
See the LICENSE.txt file for licensing information.

Abstract:
What a converted file is called, and how a source is recognised as already converted.
*/

#if os(macOS)
import Foundation

/// The name a converted film is given, and the identity two files share when they are the same
/// film in different containers.
///
/// A disc remux arrives called `Predator__Badlands_615165C3.mkv`. The library has always *displayed*
/// something better, because `FilenameMetadata` reads through the release-group noise — but the file
/// on disk kept the noise, and the file on disk is what a person sees in Finder, in a backup, on
/// another machine, and in every app that isn't this one.
///
/// So the same parse that produces the library's title produces the filename, and the two can't
/// drift because there is only one of them.
enum OutputName {
    /// What a converted source should be called, without its extension.
    ///
    /// `Predator Badlands (2025)` for a film, `Suits S01E01` for an episode. The year is included
    /// where it's known because two films share a title often enough to matter, and a season and
    /// episode are zero-padded so a folder sorts the way the series runs rather than putting
    /// episode 10 before episode 2.
    static func stem(forConverting source: URL) -> String {
        let original = source.deletingPathExtension().lastPathComponent
        let parsed = FilenameMetadata.parse(original)

        var name: String
        if let episode = parsed.episode {
            name = "\(episode.showName) S\(String(format: "%02d", episode.season))E\(String(format: "%02d", episode.episode))"
        } else if let year = parsed.year {
            name = "\(parsed.title) (\(year))"
        } else {
            name = parsed.title
        }

        name = sanitised(name)
        // A parse that produced nothing usable leaves the source's own name, which is ugly and
        // correct. Naming a film `(2019)` because the title was eaten is worse than keeping the
        // release group's name for it.
        return name.isEmpty ? original : name
    }

    /// Where a converted file goes, relative to the media folder.
    ///
    /// An episode lands in `Suits/Season 01/Suits S01E01.mp4`, because a series is the one thing a
    /// flat folder genuinely cannot hold: nine seasons of twenty-two episodes is two hundred files
    /// interleaved with everything else, and no amount of good naming makes that browsable. A film
    /// stays where it is — one file per title, which a folder each would only bury.
    ///
    /// Seasons are zero-padded for the same reason episodes are: `Season 10` sorts before
    /// `Season 2` otherwise, in Finder and in every other app that isn't this one.
    static func relativeComponents(forConverting source: URL) -> [String] {
        let stem = stem(forConverting: source)
        guard let episode = FilenameMetadata.parse(source.deletingPathExtension().lastPathComponent).episode
        else { return [stem] }
        return [sanitised(episode.showName), "Season \(String(format: "%02d", episode.season))", stem]
    }

    /// Characters removed so the result is a filename on any volume this Mac can write to.
    ///
    /// `/` is a path separator, and `:` is one too as far as the Finder is concerned — a name
    /// containing either is silently transformed or refused depending on the API that writes it.
    private static func sanitised(_ name: String) -> String {
        let stripped = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: " ")
        return stripped.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Whether two files are the same film, whatever they happen to be called.
    ///
    /// This decides whether a source has already been converted, and it used to be a comparison of
    /// raw filename stems — which worked only because the output was named after the source. Once
    /// the output is named properly, `Predator__Badlands_615165C3.mkv` and `Predator Badlands
    /// (2025).mp4` no longer look alike, and a stem comparison would re-convert every film in the
    /// folder. Unattended, with automatic conversion on, that is hours of work to produce a
    /// duplicate of something already there.
    ///
    /// So identity is what the two names *parse to*, which is the same question the library asks
    /// when it decides two files are one film.
    static func identity(of url: URL) -> String {
        stem(forConverting: url).lowercased()
    }

    /// Every video file under a folder, however deep.
    ///
    /// Recursive because the converter now writes into `Show/Season 01/`, and a flat listing would
    /// not see what it had just made. The consequence of missing one is not a cosmetic gap: an
    /// episode whose conversion is invisible is an episode that gets converted again, unattended,
    /// for hours, to produce a file that already exists.
    static func videoFiles(under folder: URL, extensions: Set<String>) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }

        var found: [URL] = []
        for case let url as URL in enumerator
        where extensions.contains(url.pathExtension.lowercased()) {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            found.append(url)
        }
        return found
    }
}
#endif
