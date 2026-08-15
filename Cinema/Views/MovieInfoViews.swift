/*
See the LICENSE.txt file for licensing information.

Abstract:
Shared TMDB-backed sections: the cast and crew row and fact labels.
*/

import SwiftUI

/// A horizontally scrolling row of cast and crew — circular photos with
/// name and role, in the TV-app style. Shared by the library's detail page
/// and the discovery sheet.
struct CastRow: View {
    let people: [TMDB.CreditedPerson]
    var horizontalPadding: Double = Constants.outerPadding

    var body: some View {
        VStack(alignment: .leading, spacing: Constants.verticalTextSpacing) {
            Text("Cast & Crew")
                .font(.headline)
                .padding(.horizontal, horizontalPadding)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Constants.cardSpacing) {
                    ForEach(people) { person in
                        PersonCard(person: person)
                    }
                }
                .padding(.horizontal, horizontalPadding)
            }
            .scrollClipDisabled()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PersonCard: View {
    let person: TMDB.CreditedPerson

    var body: some View {
        VStack(spacing: 6) {
            AsyncImage(url: person.profileURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Color(white: 0.15)
                    Image(systemName: "person.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(Circle())

            Text(person.name)
                .font(.caption.bold())
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Text(person.role)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: 90)
    }
}

/// Genre pills for plain genre names — the discovery counterpart of the
/// library's `GenreView`, sharing its visual style.
struct GenreNamesView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    let names: [String]

    var body: some View {
        HStack(spacing: Constants.genreSpacing) {
            ForEach(names, id: \.self) { name in
                Text(name)
                    .fixedSize()
                    .font(horizontalSizeClass == .compact ? .caption2 : .caption)
                    .padding(.horizontal, Constants.genreHorizontalPadding)
                    .padding(.vertical, Constants.genreVerticalPadding)
                    .background(Capsule().stroke())
            }
        }
    }
}

/// One movie fact in the TV-app's label-over-value style.
struct FactView: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
    }
}

extension TMDB.MoviePage {
    /// The runtime formatted for display, like "2h 45min", or `nil` when unknown.
    var formattedRuntime: String? {
        guard let runtime, runtime > 0 else { return nil }
        return Duration.seconds(runtime * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// The community score formatted like "★ 8.2", or `nil` when unrated.
    var formattedScore: String? {
        guard let voteAverage, voteAverage > 0 else { return nil }
        return String(format: "★ %.1f", voteAverage)
    }
}
