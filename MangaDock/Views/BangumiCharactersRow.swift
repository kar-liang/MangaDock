import SwiftUI

/// 元数据卡片下面的「角色」横向列表。
/// 纯展示：不做点击进详情 —— 角色页上的立绘是长竖条，
/// 放进小方框里无论怎么裁都会显得怪，不如就在这一行看。
struct BangumiCharactersRow: View {
    let characters: [BangumiCharacter]

    /// 横向列表放太多会滑很久，20 个够用。
    private var shown: [BangumiCharacter] {
        Array(characters.prefix(20))
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(shown) { character in
                    card(character)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(height: 160)
    }

    private func card(_ character: BangumiCharacter) -> some View {
        VStack(spacing: 6) {
            Group {
                CachedAsyncImage(url: character.portraitURL) {
                    placeholder
                }
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 96, alignment: .top)
                .clipped()
            }
            .frame(width: 72, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(character.name)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 72)

            if let relation = character.relation, !relation.isEmpty {
                Text(relation)
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(badgeColor(relation).opacity(0.15), in: Capsule())
                    .foregroundColor(badgeColor(relation))
            }
        }
        .frame(width: 72)
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
