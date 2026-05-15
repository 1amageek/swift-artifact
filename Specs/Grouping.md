# Knowledge Graph Grouping — Design Spec

`ArtifactNativeRenderer` のナレッジグラフ描画に視覚的なグループ表現を
追加するための設計仕様。本ドキュメントは実装の契約であり、各節は明示的に
informative と書かれていない限り規範的 (normative)。

---

## 1. 目的

`CompoundGraph` のパイプラインに、外的メタデータ (Named Graph / `rdf:type`
/ IRI Namespace / ユーザー指定) に由来するカードのクラスタを描画レイヤーで
可視化する **opt-in** のオーバーレイ層を追加する。

グループは **装飾的** である。新たな RDF triple を生成しない、レイアウトの
頂点にならない、エッジルーティングに介入しない。

---

## 2. 設計原則

| 原則 | 帰結 |
|-----|-----|
| IR 純度 | `CompoundGraph` 層は `SwiftUI` を import しない |
| フォーマット仕様の遵守 | 各戦略が**読むことを宣言した範囲のみ**を入力グラフから参照する |
| 合成性 | `GroupingStrategy` は enum (Hashable, 合成可能, パターンマッチ可能) |
| 決定性 | 同じ `(graph, strategy)` から同じ groups を bit 等価に生成 |
| Warm-restart 維持 | 凝集力の寄与分以外はカード位置に影響しない |
| 単一パス描画 | 既存 `KnowledgeGraphView` の Canvas にエッジより背面で描画 |

---

## 3. 非ゴール (やらない)

```
Nested groups (Group.parent)               — フラットメンバーシップのみ
Group の折りたたみ / 展開 UI              — 視覚のみ
Group の選択 / hover state                 — UI state は CompoundGraph 外
Group 間反発力                              — 凝集力のみで十分と想定
カスタム形状 (角丸 / 楕円)                 — rectangle のみ
グループ跨ぎエッジの特別描画                — 通常描画
Codable / 永続化                            — graph + strategy から再導出
任意 RGB 指定 (Tint.rgb)                   — パレット index のみ
Snapshot test                              — FR の数値ドリフトで flaky
```

---

## 4. 型定義

新規型は `Sources/ArtifactNativeRenderer/` 配下、SOLID に従い 1ファイル1型。
全公開型は `Sendable` かつ `Hashable`。

### 4.1 `CompoundGraph.Group`

`KnowledgeGraphGroup.swift`:

```swift
extension CompoundGraph {

    /// A visual cluster of cards rendered as a titled region behind its
    /// members.
    ///
    /// Groups carry no RDF semantics. A card may belong to zero, one, or
    /// several groups; membership is recorded on the group rather than on
    /// the card so adding a group never mutates any card.
    struct Group: Identifiable, Sendable, Hashable {

        struct ID: Hashable, Sendable {
            /// Strategy-prefixed (`namedGraph:` / `type:` / `namespace:` /
            /// `explicit:`) so `.combined` cannot collide across sources.
            let rawValue: String
        }

        let id: ID
        let label: String
        /// Card IDs that belong to this group. Insertion order reflects the
        /// order in which the strategy encountered them.
        let members: [Card.ID]
        let style: GroupStyle
        /// Per-group attraction strength used by the layout engine.
        /// `0` disables cohesion for this group only.
        let cohesionStrength: Double
    }
}
```

### 4.2 `GroupStyle`, `Tint`, `Outline`

`KnowledgeGraphGroupStyle.swift`:

```swift
struct GroupStyle: Sendable, Hashable {
    var tint: Tint = .auto
    var outline: Outline = .dashed
    var opacity: Double = 0.10

    enum Tint: Sendable, Hashable {
        /// Renderer assigns from its palette using the group's index in
        /// `CompoundGraph.groups`.
        case auto
        /// Renderer uses the Nth slot of its palette, modulo palette size.
        case palette(Int)
    }

    enum Outline: Sendable, Hashable {
        case solid
        case dashed
        case none
    }

    static let `default` = GroupStyle()
}
```

`GroupStyle` は IR 層に住むので **SwiftUI 非依存**。`Tint` から
`SwiftUI.Color` への解決はレンダラ層 (§8.2)。

### 4.3 `GroupingStrategy`

`KnowledgeGraphGroupingStrategy.swift`:

```swift
enum GroupingStrategy: Sendable, Hashable {

    /// Produce no groups.
    case none

    /// One group per `KnowledgeGraph.namedGraphs` entry, after filtering
    /// for non-empty membership (literal-folding may empty some).
    case namedGraphs(cohesionStrength: Double = 0.05)

    /// One group per distinct `rdf:type` (sourced from `Node.types`).
    case byType(cohesionStrength: Double = 0.05)

    /// One group per `Namespace`. Longest-prefix wins when multiple
    /// declared URIs match.
    case byNamespace(cohesionStrength: Double = 0.05)

    /// User-supplied groups. Member IDs are filtered against the actual
    /// card set; an invalid ID is dropped silently.
    case explicit(groups: [CompoundGraph.Group])

    /// Union of sub-strategy outputs, with collision dedup.
    indirect case combined([GroupingStrategy])
}
```

`CompoundGraph.decompose` のデフォルトは
`.namedGraphs(cohesionStrength: 0.05)`。Named Graph を持たないフォーマット
(Turtle, RDF/XML, plain JSON-LD) では空配列となり no-op になるので
フォーマット別の分岐不要。

### 4.4 `CompoundGraph` の拡張

`KnowledgeGraphCompoundGraph.swift` (modify):

```swift
struct CompoundGraph: Sendable {

    let cards: [Card]
    let edges: [CardEdge]
    let groups: [Group]                          // NEW
    let cardByID: [Card.ID: Card]
    let groupByID: [Group.ID: Group]             // NEW, derived
    /// Reverse index. Absent for cards in no group — `nil` rather than
    /// empty array to avoid extra allocations.
    let groupsByCard: [Card.ID: [Group.ID]]      // NEW, derived
}
```

### 4.5 `KnowledgeGraphLayout.Result` の拡張

`KnowledgeGraphLayout.swift` (modify):

```swift
struct Result: Sendable {
    let compoundGraph: CompoundGraph
    let cardPositions: [CompoundGraph.Card.ID: CGPoint]
    let edgeRoutes: [EdgeIdentifier: EdgeRoute]
    let edgeLabelPositions: [EdgeIdentifier: CGPoint]
    let groupBoundingBoxes: [CompoundGraph.Group.ID: CGRect]   // NEW
    let canvasSize: CGSize
}
```

---

## 5. 戦略のセマンティクス

### 5.1 `.none`

```
deriveGroups(.none, graph, cards) → []
```

### 5.2 `.namedGraphs(cohesionStrength:)`

```
inputs:
    graph.namedGraphs:  [NamedGraph]      with (id, label?, nodes, edges)
    cards:              [Card]            (post-decompose)
    cohesionStrength:   Double

output:
    for each ng in graph.namedGraphs (in insertion order):
        members = ng.nodes
                    .filter { validCardIDs.contains($0) }
                    .map    { Card.ID(nodeID: $0) }
        id      = Group.ID(rawValue: "namedGraph:\(ng.id)")
        label   = ng.label ?? shortener.shortenIRI(ng.id)
        style   = .default
        emit Group iff !members.isEmpty
```

`validCardIDs` は実際にカードを持つ `NodeIdentifier` 集合 (リテラル折りたたみ
で消えたものは含まれない)。

### 5.3 `.byType(cohesionStrength:)`

```
inputs:
    graph.nodes[i].types : [String]       parser によって既に populate 済
    cards
    shortener

output:
    for each distinct type IRI t in first-occurrence order:
        members = cards whose source node lists t in `types`
        id      = Group.ID(rawValue: "type:\(t)")
        label   = shortener.shortenIRI(t)
        style   = .default
        emit iff !members.isEmpty
```

複数 type を持つノードは複数グループに重複所属する (これは仕様)。

### 5.4 `.byNamespace(cohesionStrength:)`

```
inputs:
    graph.namespaces : [Namespace] with (prefix, uri)
    cards

output:
    for each ns in graph.namespaces (declaration order):
        members = cards whose card.id.nodeID is an IRI whose `key` starts
                  with ns.uri AND for which ns.uri is the longest matching
                  namespace URI across graph.namespaces.
                  Literal / blank nodes never match.
        id      = Group.ID(rawValue: "namespace:\(ns.prefix)")
        label   = ns.prefix
        style   = .default
        emit iff !members.isEmpty
```

`http://example.org/` と `http://example.org/people/` が両方宣言されて
いる場合、people IRI は people グループにのみ属する (longest-prefix wins)。

### 5.5 `.explicit(groups:)`

```
inputs:
    user-supplied groups: [Group]
    cards

output:
    for each g in input order:
        filtered = g.members.filter { validCardIDs.contains($0.nodeID) }
        if filtered.isEmpty: drop g
        else:
            id = g.id.rawValue.hasPrefix("explicit:")
                   ? g.id
                   : Group.ID(rawValue: "explicit:" + g.id.rawValue)
            emit g with .members = filtered, .id = id
```

無効な member ID は silent filter (外部入力なので寛容に扱う)。
**内部戦略 (`.namedGraphs` / `.byType` / `.byNamespace`)** は無効 member を
出力した時点で構築バグであり、実装側で `precondition` してよい。

### 5.6 `.combined([...])`

```
inputs:
    sub-strategies: [GroupingStrategy]

output:
    raw = sub-strategies.flatMap { deriveGroups($0, graph, cards) }
    return dedup(raw)

dedup criterion:
    two groups are duplicates iff
        a.label == b.label
        AND sorted(a.members.map(\.nodeID))
            == sorted(b.members.map(\.nodeID))
    Keep the first occurrence.
```

---

## 6. Decompose のフロー

`CompoundGraph.decompose(_:groupingStrategy:)` の処理順:

```
1. existing card / edge construction        (変更なし)
2. groups = deriveGroups(strategy, graph, cards)
3. groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
4. groupsByCard = invert(groups)
5. return CompoundGraph(cards, edges, groups, cardByID, groupByID, groupsByCard)
```

`deriveGroups` は enum case で dispatch、`.combined` は再帰。

シグネチャ:

```swift
extension CompoundGraph {
    static func decompose(
        _ graph: KnowledgeGraph,
        groupingStrategy: GroupingStrategy = .namedGraphs(cohesionStrength: 0.05)
    ) -> CompoundGraph
}
```

凝集力は戦略 enum から `Group` に伝播される (生成時に書き込む)。
`.combined` は各サブ戦略の cohesionStrength をそのまま使う (全体上書きなし)。

---

## 7. レイアウト統合

`KnowledgeGraphLayout.compute(graph:iterations:initial:)` に 2 つを追加。

### 7.1 FR ループ内のグループ凝集力

Coulomb 反発 と バネ引力 の後、温度キャップの前:

```
for each group g in compound.groups where g.cohesionStrength > 0:
    indices = g.members.compactMap { indexByCardID[$0] }
    guard indices.count >= 2 else: continue       // 単一メンバはスキップ
    let c = centroid(working[indices])
    for i in indices:
        dispX[i] += (c.x - Double(working[i].x)) * g.cohesionStrength
        dispY[i] += (c.y - Double(working[i].y)) * g.cohesionStrength
```

iter あたりコスト: O(Σ |members|)。200 iter × 数百 member で 1ms 以下。

数値的注意:
- 単一メンバはスキープ — 力は 0 だが centroid 計算を省ける
- 全 member が同一座標 → 力 0、NaN なし

### 7.2 グループ bbox 計算

`anchorAndCanvas` 後の `cardPositions` を使って:

```swift
private static func computeGroupBoundingBoxes(
    groups: [CompoundGraph.Group],
    cards: [CompoundGraph.Card],
    indexByCardID: [CompoundGraph.Card.ID: Int],
    cardPositions: [CompoundGraph.Card.ID: CGPoint],
    padding: CGFloat = 24
) -> [CompoundGraph.Group.ID: CGRect]
```

各グループについて:
1. members を走査し、card 矩形の min/max x/y を集計
2. 各辺に `padding` を加える
3. 結果 dict に格納。member がいずれも cardPositions に存在しない (理論上
   起きない) ケースは skip。

`padding` 推奨初期値: **24 pt**。

### 7.3 ラベル余白のためのキャンバス拡大

現在の `anchorAndCanvas` は `padding = 36`。`groups.isEmpty == false` の
ときは `36 + 28 = 64` に増やす (ラベル高さ ~22 + 余白 4 + 余裕)。

---

## 8. レンダリング

### 8.1 Z-order

`KnowledgeGraphView.canvasContent` の Canvas 内で:

```
1. drawGroups(...)     — NEW    塗りつぶし + 枠 + ラベル
2. drawEdges(...)      — existing
3. drawEdgeLabels(...) — existing
4. drawCards(...)      — existing (symbols 経由)
```

グループはエッジより背面で描画 → エッジが視覚的にグループの上を通る。

### 8.2 Tint 解決とパレット

`GroupPalette` はレンダラ層 (SwiftUI 可) に住む。

`KnowledgeGraphGroupPalette.swift`:

```swift
import SwiftUI

struct GroupPalette: Sendable {
    let colors: [Color]

    func color(at index: Int) -> Color {
        guard !colors.isEmpty else { return .gray }
        let i = ((index % colors.count) + colors.count) % colors.count
        return colors[i]
    }

    static let `default` = GroupPalette(colors: [
        .blue, .green, .orange, .purple, .pink,
        .teal, .yellow, .red, .mint, .indigo
    ])
}
```

解決:

```swift
extension GroupStyle.Tint {
    func resolve(palette: GroupPalette, autoIndex: Int) -> Color {
        switch self {
        case .auto:               return palette.color(at: autoIndex)
        case .palette(let slot):  return palette.color(at: slot)
        }
    }
}
```

`autoIndex` は `compound.groups` 内のオフセット。

### 8.3 グループ描画

各グループについて、`bbox = result.groupBoundingBoxes[group.id]` を使い:

```
1. 塗りつぶし: tint.resolve(...).opacity(group.style.opacity)
2. 枠線:
   - .solid:  StrokeStyle(lineWidth: 1)
   - .dashed: StrokeStyle(lineWidth: 1, dash: [4, 4])
   - .none:   描画しない
   枠線色: tint をフルアルファ、0.6 透明
3. ラベル: Canvas.resolve(...) で 1 行テキスト
   位置: (bbox.minX, bbox.minY - labelHeight - 4)
   テキスト: group.label
```

ラベルフォントは edge label と同じ小サイズシステムフォント。

### 8.4 多重所属の重なり

2 グループの bbox が重なる場合、両方をそれぞれの opacity で描画する。
SwiftUI のコンポジットが自然に交差領域を濃くする (0.10 × 0.10 ≈ 0.19)。
特別ロジック不要。

### 8.5 ビューポートカリング

`drawGroups` も既存のカリングに参加:

```
let visibleRect = ...
for (group, autoIndex) in compound.groups.enumerated():
    guard let bbox = groupBoundingBoxes[group.id] else: continue
    let bboxScreen = viewport.canvasToScreen(rect: bbox)
    guard bboxScreen.intersects(visibleRect) else: continue
    drawGroup(...)
```

---

## 9. 不変条件

`CompoundGraph` (decompose の出力):

```
I1. groups.allSatisfy { !$0.members.isEmpty }
I2. groups.allSatisfy { $0.members.allSatisfy { cardByID[$0] != nil } }
I3. ∀ group: groupByID[group.id] == group
I4. ∀ card ∈ group.members: group.id ∈ groupsByCard[card] ?? []
I5. ∀ card ∈ groupsByCard.keys: !groupsByCard[card]!.isEmpty
I6. Group.ID.rawValue は次のいずれかで始まる:
    "namedGraph:" | "type:" | "namespace:" | "explicit:"
```

`KnowledgeGraphLayout.Result`:

```
L1. ∀ card.id: cardPositions[card.id] が non-nil かつ finite
L2. ∀ group: groupBoundingBoxes[group.id] が全 member の矩形を含む
L3. ∀ group: groupBoundingBoxes[group.id] が finite (Inf / NaN なし)
```

---

## 10. ファイル構成

```
Sources/ArtifactNativeRenderer/
├── KnowledgeGraphCompoundGraph.swift       MODIFY  (groups field, derive 呼び出し)
├── KnowledgeGraphGroup.swift               NEW     (Group, Group.ID)
├── KnowledgeGraphGroupStyle.swift          NEW     (GroupStyle, Tint, Outline)
├── KnowledgeGraphGroupingStrategy.swift    NEW     (GroupingStrategy + deriveGroups)
├── KnowledgeGraphGroupPalette.swift        NEW     (GroupPalette; SwiftUI-aware)
├── KnowledgeGraphLayout.swift              MODIFY  (cohesion + bbox + Result field)
└── KnowledgeGraphView.swift                MODIFY  (drawGroups + palette 接続)

Tests/ArtifactNativeRendererTests/
├── CompoundGraphGroupTests.swift           NEW
├── KnowledgeGraphLayoutGroupTests.swift    NEW
└── Fixtures/Groups/
    ├── two-disjoint-graphs.trig
    ├── two-connected-graphs.trig
    ├── single-large-group.trig
    ├── three-overlapping-groups.ttl
    ├── literal-only-named-graph.trig
    ├── byType-mixed.ttl
    ├── byType-multitype.ttl
    ├── byNamespace.ttl
    └── combined-namedGraphs-and-types.trig
```

---

## 11. テスト計画

### 11.1 戦略ユニットテスト (`CompoundGraphGroupTests.swift`)

```
groupingStrategyNoneProducesNoGroups
namedGraphsStrategyProducesOneGroupPerNamedGraph
emptyGroupsAreFilteredAfterLiteralFolding
byTypeStrategyGroupsByRdfType
byTypeAllowsMultipleMembershipForMultiTypedNode
byNamespaceStrategyGroupsByIriPrefix
byNamespaceUsesLongestPrefixMatch
explicitStrategyFiltersInvalidCardIDs
combinedStrategyDeduplicatesByLabelAndMembers
groupIDsArePrefixedPerStrategyToAvoidCollision
groupsByCardIsReverseMapOfGroupMembers
groupsByCardIsAbsentForUnassignedCards
```

### 11.2 レイアウトテスト (`KnowledgeGraphLayoutGroupTests.swift`)

```
disjointNamedGraphsProduceDisjointBoundingBoxes
groupBoundingBoxContainsAllMemberCards
cohesionForceDoesNotProduceNaN
boundingBoxIsFiniteForSingleMemberGroup
```

### 11.3 Fixtures

各 TriG / Turtle fixture は既存の `KnowledgeGraphParsers` で parse →
`CompoundGraph.decompose` に渡してテスト。サイズは ≤ 15 ノード。

### 11.4 視覚 fixture (Previews)

各 fixture を `#Preview` で `KnowledgeGraphView` に並べる。PR レビューで
スクショ確認。D2/D3/D5 の閾値キャリブレーションは目視確認後に行う。

---

## 12. キャリブレーション

End-to-end の最初の通しを実行し、各 fixture について計測:

```
groupArea / canvasArea         each group
bboxA ∩ bboxB                  disjoint fixtures
```

観測した最悪値の 10% 上に閾値を固定し、`KnowledgeGraphLayoutGroupTests.swift`
冒頭コメントに**キャリブレーション日と使用 fixture**を記録する (後の
ドリフト検知のため)。

---

## 13. 実装順序

```
Step 1 — Types
        KnowledgeGraphGroup.swift
        KnowledgeGraphGroupStyle.swift
        KnowledgeGraphGroupingStrategy.swift (stub deriveGroups returning [])
        CompoundGraph.{groups, groupByID, groupsByCard} を配線

Step 2 — .namedGraphs 戦略 + decompose 配線
        空グループフィルタ
        .none と .namedGraphs のユニットテスト

Step 3 — FR ループ内の凝集力
        単一メンバ skip, NaN 安全性テスト

Step 4 — Bounding box + Result への配線
        anchorAndCanvas の padding をラベル分拡大

Step 5 — KnowledgeGraphView の drawGroups
        GroupPalette + Tint.resolve
        Z-order 再配線
        Group bbox のビューポートカリング

Step 6 — 残戦略
        .byType
        .byNamespace (longest-prefix)
        .explicit (invalid ID filter)
        .combined (dedup)

Step 7 — Fixtures + Previews + 視覚レビュー

Step 8 — D2 / D3 / D5 閾値キャリブレーション
```

各 step は単独でコンパイル可、既存テストが通る、新規テストが追加されて
通る、を満たしてから次に進む。
