import SwiftUI

/// 元数据卡片下面的「角色」横向列表。
/// 点一个角色会弹出详情（Bangumi 的角色简介比作品简介更有意思）。
struct BangumiCharactersRow: View {
    let characters: [BangumiCharacter]

    @State private var selected: BangumiCharacter?

    /// 横向列表放太多会滑很久，20 个够用。
    private var shown: [BangumiCharacter] {
        Array(characters.prefix(20))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(shown) { character in
                    Button {
                        selected = character
                    } label: {
                        card(character)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 186)
        .sheet(item: $selected) { character in
            BangumiCharacterDetail(character: character)
        }
    }

    private func card(_ character: BangumiCharacter) -> some View {
        VStack(spacing: 6) {
            Group {
                if let url = character.portraitURL {
                    AsyncImage(url: url) { phase in
                        if case .success(let image) = phase {
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 88, height: 118, alignment: .top)
                                .clipped()
                        } else {
                            placeholder
                        }
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: 88, height: 118)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(character.name)
                .font(.footnote.weight(.medium))
                .lineLimit(1)
                .frame(width: 88)

            if let relation = character.relation, !relation.isEmpty {
                Text(relation)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor(relation).opacity(0.15), in: Capsule())
                    .foregroundColor(badgeColor(relation))
            }
        }
        .frame(width: 88)
        .contentShape(Rectangle())
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.1)
            Image(systemName: "person.fill")
                .font(.system(size: 20))
                .foregroundColor(.secondary.opacity(0.4))
        }
    }

    /// 主角给强调色，配角走次要色，客串更淡。
    private func badgeColor(_ relation: String) -> Color {
        if relation.contains("主角") { return .accentColor }
        if relation.contains("客串") { return .secondary.opacity(0.7) }
        return .secondary
    }
}

/// 单个角色的详情。
struct BangumiCharacterDetail: View {
    let character: BangumiCharacter

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 14) {
                        Group {
                            if let url = character.portraitURL {
                                AsyncImage(url: url) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Color.secondary.opacity(0.1)
                                    }
                                }
                            } else {
                                Color.secondary.opacity(0.1)
                            }
                        }
                        .frame(width: 110, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(character.name)
                                .font(.title3.weight(.semibold))
                            if let relation = character.relation, !relation.isEmpty {
                                Text(relation)
                                    .font(.caption)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    .foregroundColor(.accentColor)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    if let summary = character.summary,
                       !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(summary)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(20)
            }
            .navigationTitle("角色")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
