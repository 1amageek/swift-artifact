# Knowledge Graph Grouping — Goal Conditions

`Specs/Grouping.md` の実装が完了したと判定するための条件一覧。
**MUST** はリリース必須、**SHOULD** は強く推奨、**OPTIONAL** は将来対応可。

`/goal` の入力としてそのまま参照可能な形式で記述してある。

---

## A. RDF / フォーマット仕様 (MUST)

| # | 条件 |
|---|------|
| A1 | Group は `KnowledgeGraph` に triple を追加しない (`decompose` は graph を read-only に扱う) |
| A2 | `.namedGraphs` は `graph.namedGraphs` 配列の中身だけを参照し、TriG / JSON-LD の Named Graph 意味論に介入しない |
| A3 | `.byType` は `Node.types` のみを参照、`rdfs:Class` などへの推論は行わない |
| A4 | `.byNamespace` は `graph.namespaces` の longest-prefix 一致のみで判定する (推論なし) |
| A5 | Turtle / RDF/XML 入力で `.namedGraphs` 戦略を使った場合、結果の `groups` は空配列 |

---

## B. 戦略の正しさ (MUST)

| # | 条件 | fixture |
|---|------|---------|
| B1 | `.namedGraphs`: 全 named graph で `members.isEmpty == false` のものが Group になる | `two-disjoint-graphs.trig` |
| B2 | 全 member がリテラル折りたたみで消えた named graph は**出力に含まれない** | `literal-only-named-graph.trig` |
| B3 | `.byType`: 同一 `rdf:type` ノードが 1 グループ | `byType-mixed.ttl` |
| B4 | `.byType`: 多 type ノードはそれぞれのグループに重複所属 | `byType-multitype.ttl` |
| B5 | `.byNamespace`: 同一 IRI prefix で 1 グループ | `byNamespace.ttl` |
| B6 | `.byNamespace`: 複数 namespace が前方一致する場合、**longest** が勝つ | `byNamespace.ttl` (overlapping prefixes) |
| B7 | `.explicit([groups])`: invalid card ID は filter、valid のみ通過 | `explicitStrategyFiltersInvalidCardIDs` |
| B8 | `.combined([...])`: サブ戦略の union | `combined-namedGraphs-and-types.trig` |
| B9 | `.combined`: `(label, sortedMembers)` 一致のグループは dedup される | `combinedStrategyDeduplicatesByLabelAndMembers` |
| B10 | `Group.ID` の prefix (`namedGraph:` / `type:` / `namespace:` / `explicit:`) で衝突しない | 同名 IRI fixture |

---

## C. 派生フィールド (MUST)

| # | 条件 |
|---|------|
| C1 | `compound.groupByID[id]?.members.contains(cardID)` と `compound.groupsByCard[cardID]?.contains(id)` が双方向整合 |
| C2 | グループに属さないカードは `groupsByCard[cardID] == nil` (空配列ではない) |
| C3 | `compound.groups.allSatisfy { !$0.members.isEmpty }` |

---

## D. レイアウト品質 (MUST)

基本制約は `Specs/KnowledgeGraphLayout.md` を正とする。
Grouping はその上に group outline を描画する機能であり、Edge / Node / Group の
幾何制約を上書きしない。

戦略 `!= .none` の条件下で:

| # | 条件 | 閾値 (キャリブレーション後 — 2026-05-15) |
|---|------|----------------------------------|
| D1 | 全 member の `card.frame` が group bbox 内 (padding 込み) | — |
| D2 | 連結グループの bbox タイト性 (5 ノード 1 グループ) | `bbox.area < canvas.area × 0.85` (実測 0.80) |
| D3 | 孤立グループの bbox タイト性 (2 グループ × 3 ノード) | `bbox.area < canvas.area × 0.50` |
| D4 | 孤立 2 グループの bbox 非交差 | `bboxA ∩ bboxB == ∅` |
| D5 | 単一大グループの bbox タイト性 (8 ノード 1 グループ) | `bbox.area < canvas.area × 0.90` (実測 0.88) |
| D6 | 全 `cardPosition.x, .y` が `.isFinite` |
| D7 | 凝集力ありで NaN/Inf が発生しない (単一メンバ / 重複座標保護) |
| D8 | Edge segment は水平または垂直のみ (`KnowledgeGraphLayout.md` L1) | — |
| D9 | Edge は endpoint ではない Node に被らない (`KnowledgeGraphLayout.md` L3) | — |
| D10 | Edge は Node の辺に法線方向で接続 (`KnowledgeGraphLayout.md` L2) | — |
| D11 | Edge route は制約を満たす候補の中で短い候補を優先し、同程度なら角数が少ない候補を優先 (`KnowledgeGraphLayout.md` L4) | — |

---

## E. 型安全性 (MUST)

| # | 条件 |
|---|------|
| E1 | `KnowledgeGraphCompoundGraph.swift` および `KnowledgeGraphGroup.swift` / `KnowledgeGraphGroupStyle.swift` / `KnowledgeGraphGroupingStrategy.swift` の import が `Foundation` + `CoreGraphics` のみ (SwiftUI 非依存) |
| E2 | 全公開型 `Sendable` |
| E3 | 全公開型 `Hashable` |
| E4 | `GroupingStrategy` 全 case が default 引数付き associated value で宣言 |
| E5 | `try?` 不使用、silent fallback なし |
| E6 | `KnowledgeGraphGroupPalette.swift` のみ `SwiftUI` を import する |

---

## F. 描画 (MUST)

| # | 条件 | 検証方法 |
|---|------|---------|
| F1 | Z-order: groups → edges → edgeLabels → cards (背面 → 前面) | Preview 目視 |
| F2 | `GroupStyle.opacity` が塗りつぶしに反映 | Preview 目視 |
| F3 | `Outline.dashed` がデフォルト、点線描画 | Preview 目視 |
| F4 | `Outline.none` で枠線なし | Preview 目視 |
| F5 | `Tint.auto` で group index ベースに区別可能な色を割り当て | Preview (3+ グループ) |
| F6 | `Tint.palette(n)` で同じ `n` のグループは同色 | Preview |
| F7 | 多重所属の bbox 重なりが**両方の半透明色を混合** | Preview (overlapping) |
| F8 | ラベルは bbox 左上**外側** (`bbox.minY - labelHeight - 4`) に描画 | Preview |
| F9 | Canvas 1 枚で完結 (`KnowledgeGraphCanvasHost` を増やさない) | コード |
| F10 | 既存のビューポートカリングが group bbox にも適用される | コード |

---

## G. テストカバレッジ (MUST)

`CompoundGraphGroupTests.swift`:

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

`KnowledgeGraphLayoutGroupTests.swift`:

```
disjointNamedGraphsProduceDisjointBoundingBoxes
groupBoundingBoxContainsAllMemberCards
cohesionForceDoesNotProduceNaN
boundingBoxIsFiniteForSingleMemberGroup
```

---

## H. Fixture (MUST)

`Tests/ArtifactRendererTests/Fixtures/Groups/`:

```
two-disjoint-graphs.trig
two-connected-graphs.trig
single-large-group.trig
three-overlapping-groups.ttl
literal-only-named-graph.trig
byType-mixed.ttl
byType-multitype.ttl
byNamespace.ttl
combined-namedGraphs-and-types.trig
```

各 fixture について `KnowledgeGraphView` に `#Preview` を追加。PR 時に
スクショで視覚確認する。

---

## I. パフォーマンス (SHOULD)

| # | 条件 |
|---|------|
| I1 | 凝集力追加が FR 1 iter あたり `O(Σ\|members\|)` |
| I2 | bbox 計算は decompose 後 1 回のみ、`O(Σ\|members\|)` |
| I3 | `groupsByCard` 構築は decompose 内 1 回のみ |
| I4 | `.combined` の dedup が `O((Σ groups) log (Σ groups))` 以下 |

---

## J. 非ゴール (やらない)

```
Group.parent (ネスト階層)
グループの折りたたみ / 展開 UI
グループの選択 / ハイライト状態
グループ間反発力
カスタム形状 (角丸 / 楕円)
グループ跨ぎエッジの特別描画
Codable / 永続化
Tint.rgb(...) (任意色指定)
Snapshot test
```

---

## K. 完了判定フロー

```
Step 1: 型追加
        ↓ E1–E6 + コンパイル
Step 2: .namedGraphs 戦略
        ↓ A1, A2, A5, B1, B2, C1–C3
Step 3: 凝集力 in FR
        ↓ D6, D7 + I1
Step 4: bbox 計算
        ↓ D1, L1–L3
Step 5: 描画 + Preview
        ↓ F1–F10 + H (fixtures Preview 目視)
Step 6: 残戦略 (.byType / .byNamespace / .explicit / .combined)
        ↓ A3, A4, B3–B10
Step 7: 全テスト pass
        ↓ G
Step 8: 実測キャリブレーション (D2/D3/D5 の閾値確定)
        ↓ 完了
```
