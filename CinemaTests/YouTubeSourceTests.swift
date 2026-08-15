/*
See the LICENSE.txt file for licensing information.

Abstract:
Tests for YouTube URL parsing.
*/

import Foundation
import Testing
@testable import Cinema

@Suite("YouTube URL parsing")
struct YouTubeSourceTests {

    @Test("Extracts the video ID from every supported URL shape", arguments: [
        ("https://www.youtube.com/watch?v=aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://youtube.com/watch?v=aqz-KE-bpKQ&t=42s", "aqz-KE-bpKQ"),
        ("https://m.youtube.com/watch?v=aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://music.youtube.com/watch?v=aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://youtu.be/aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://youtu.be/aqz-KE-bpKQ?si=share-token", "aqz-KE-bpKQ"),
        ("https://www.youtube.com/shorts/aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://www.youtube.com/embed/aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://www.youtube.com/live/aqz-KE-bpKQ", "aqz-KE-bpKQ"),
        ("https://www.youtube.com/v/aqz-KE-bpKQ", "aqz-KE-bpKQ"),
    ])
    func extractsVideoID(urlString: String, expectedID: String) throws {
        let url = try #require(URL(string: urlString))
        #expect(YouTubeSource.videoID(from: url) == expectedID)
    }

    @Test("Rejects non-YouTube and malformed URLs", arguments: [
        "https://example.com/watch?v=aqz-KE-bpKQ",
        "https://notyoutube.com/watch?v=aqz-KE-bpKQ",
        "https://www.youtube.com/feed/subscriptions",
        "https://www.youtube.com/watch",
        "https://vimeo.com/12345",
    ])
    func rejectsForeignURLs(urlString: String) throws {
        let url = try #require(URL(string: urlString))
        #expect(YouTubeSource.videoID(from: url) == nil)
    }

    @Test("Canonical watch URL round-trips through the parser")
    func watchURLRoundTrips() {
        let watchURL = YouTubeSource.watchURL(forVideoID: "aqz-KE-bpKQ")
        #expect(YouTubeSource.videoID(from: watchURL) == "aqz-KE-bpKQ")
        #expect(YouTubeSource.isYouTubeURL(watchURL))
    }
}
