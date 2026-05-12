# Bob Artifact Library 仕様書

**Version**: 0.1.0-draft
**Date**: 2026-05-12
**Target**: Swift 6.2+ / iOS 26+ / macOS 26+ / iPadOS 26+

---

## 1. 概要

Bob Artifact Library は、LLM が生成する `<artifact>` タグを含む文章を Swift / SwiftUI で表示するためのライブラリ。チャットインターフェースの 1 メッセージバブル内に組み込んで使用する。

### 1.1 設計原則

1. **責務分離**: パース、モデル、表示、レンダラーを独立した型で分離する
2. **値型優先**: モデルは struct、参照型は表示・ランタイム層に限定する
3. **プロトコル駆動**: レンダラーは `ArtifactRenderable` プロトコル準拠のみを要件とし、グローバル Registry や hardcoded switch を持たない
4. **コンパイル時決定**: 標準レンダラーの選択は型システムで決定、ランタイム動的辞書を持たない
5. **Partial 対応**: ストリーミング中の中途半端な状態でも表示可能、または Progress を表示する切り分けを型で表現
6. **Web 標準準拠**: ArtifactType は MIME タイプ空間に直結、Claude のフォーマットと互換

### 1.2 ライブラリの責務範囲

#### 範囲内

- `<artifact>` タグを含む文字列のパース
- `ArtifactMessage` モデル
- 1 メッセージ分の Canvas 表示
- 個別アーティファクトの View 表示
- 標準 Renderer 群（Tier 1 + Tier 2）
- `ArtifactRenderable` プロトコル

#### 範囲外

- チャット UI（バブル、スクロール、入力欄）
- 会話履歴管理
- LLM API 呼び出し
- 永続化
- 認証・ネットワーク

---

## 2. アーキテクチャ

### 2.1 レイヤー構造

```
┌─ ChatView (アプリ側) ───────────────────┐
│  ┌─ Bubble (アプリ側) ────────────┐   │
│  │  ┌─ ArtifactCanvas (Bob) ────┐ │   │
│  │  │  Text / Markdown 散文      │ │   │
│  │  │  ┌─ ArtifactCard (Bob) ─┐ │ │   │
│  │  │  │ ┌─ ArtifactView ──┐ │ │ │   │
│  │  │  │ │   Renderer       │ │ │ │   │
│  │  │  │ └──────────────────┘ │ │ │   │
│  │  │  └──────────────────────┘ │ │   │
│  │  │  Text / Markdown 散文      │ │   │
│  │  └────────────────────────────┘ │   │
│  └──────────────────────────────────┘   │
└──────────────────────────────────────────┘
```

### 2.2 モジュール構成

```
BobArtifact/
├── ArtifactCore/           # パース、モデル
├── ArtifactRenderer/       # Renderer プロトコル
├── ArtifactRendererNative/ # ネイティブ実装群
├── ArtifactRendererWeb/    # WKWebView 実装群
└── ArtifactView/           # SwiftUI View 群
```

`ArtifactRendererNative` と `ArtifactRendererWeb` は別ターゲット。利用者は必要な方だけを依存に含める。

---

## 3. 責務分離: Agent / Parser / Renderer

### 3.1 Agent の責務

LLM (Agent) は `<artifact>` タグの開始から終了までを文字列として生成する。タグ内部に書く内容は `type` 属性によって決まる仕様に従う。

```
<artifact type="application/vnd.ant.react"
          identifier="counter"
          title="Counter">
┌─────────────────────────────────────────┐
│ Agent はこの内部だけを生成する責務        │
│ (ペイロード本体)                         │
└─────────────────────────────────────────┘
</artifact>
```

### 3.2 Parser の責務

- 散文と `<artifact>` タグの仕分け
- タグの属性パース (`type`, `identifier`, `title`, その他)
- ペイロード本文の切り出し
- ストリーミング中の中間状態の管理

### 3.3 Renderer の責務

- type 別のペイロード解釈
- View の構築
- Partial / Complete 状態の判定

---

## 4. コアモデル

### 4.1 `ArtifactType`

MIME タイプ空間に直結する識別子。

```swift
public struct ArtifactType: RawRepresentable, Hashable, Sendable, Codable,
                            ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String)
    public init(_ rawValue: String)
    public init(stringLiteral value: String)
    public var description: String { rawValue }
}
```

**設計判断**: enum ではなく struct + RawRepresentable。理由:

- MIME タイプ空間は本質的に開かれた集合
- ライブラリ外からの拡張（Tier 3 の独自 type）が必須
- `Notification.Name`, `SwiftUI.Font.Design` と同じパターン

### 4.2 `ArtifactIdentifier`

アーティファクトインスタンスの一意 ID。

```swift
public struct ArtifactIdentifier: RawRepresentable, Hashable, Sendable, Codable,
                                  ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String)
    public init(_ rawValue: String)
    public init(stringLiteral value: String)
}
```

`ArtifactType` と分離。前者は「種類」、後者は「個別インスタンス」。

### 4.3 `AnyArtifact`

パース結果を保持する値型。完成形・中間状態どちらも表現する。

```swift
public struct AnyArtifact: Identifiable, Sendable, Equatable {
    public typealias ID = ArtifactIdentifier

    public let id: ArtifactIdentifier
    public let type: ArtifactType
    public let title: String
    public let attributes: [String: String]

    /// ストリーミングで増加する本体
    public let payload: String

    /// </artifact> を受信済みか
    public let isComplete: Bool
}
```

**設計判断**:

- `class` ではなく `struct`: 値型、Equatable、SwiftUI の差分検出が自然に効く
- Partial は別型 (`PartiallyArtifact`) ではなく `AnyArtifact` 自身が表現
- 理由: Artifact のペイロードは多くが文字列であり、`@Generable` のような「フィールド単位 Optional 化」より「payload がどこまで届いたか」がより本質的

### 4.4 `RawArtifact`

具体型 (`Artifactable`) との変換に使う中間表現。

```swift
public struct RawArtifact: Sendable, Equatable {
    public let identifier: ArtifactIdentifier
    public let type: ArtifactType
    public let title: String
    public let payload: String
    public let attributes: [String: String]
}
```

### 4.5 `ArtifactMessage`

1 メッセージ（チャットバブル 1 個分）のモデル。散文と複数の Artifact が混在する。

```swift
public struct ArtifactMessage: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let segments: [Segment]

    public enum Segment: Identifiable, Sendable, Equatable {
        case text(String)
        case artifact(AnyArtifact)

        public var id: String { ... }
    }
}

extension ArtifactMessage {
    public static let empty: ArtifactMessage
}
```

---

## 5. プロトコル

### 5.1 `Artifactable`

具体的なアーティファクト型のプロトコル。`RawArtifact` との相互変換を定義。

```swift
public protocol Artifactable: Sendable {
    static var artifactType: ArtifactType { get }

    init(from raw: RawArtifact) throws
    var rawArtifact: RawArtifact { get }
}
```

### 5.2 `ArtifactRenderable`

レンダラーのプロトコル。これに準拠していればレンダラーとして使える。

```swift
public protocol ArtifactRenderable {
    associatedtype Body: View

    static var artifactType: ArtifactType { get }

    @MainActor @ViewBuilder
    func body(artifact: AnyArtifact) -> Body

    /// このレンダラーが現在の artifact をどう描画すべきかを返す
    static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState
}

extension ArtifactRenderable {
    /// デフォルト: 完成時のみ描画
    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        artifact.isComplete ? .complete : .streaming
    }
}
```

**設計判断**: Registry を持たない。利用者が型パラメータで Renderer を選ぶ。

### 5.3 `ArtifactRenderingState`

レンダリング状態を表す enum。

```swift
public enum ArtifactRenderingState: Sendable, Equatable {
    /// 何も受信していない
    case empty

    /// 受信中。Progress 表示すべき
    case streaming

    /// 中間状態だが描画可能
    case partial

    /// 完成
    case complete
}
```

**重要**: `streaming` と `partial` の判定はレンダラーの責務。

- レンダラーが partial 対応している → `streaming` ではなく `partial` を返す
- レンダラーが完成必須 → 未完成時は `streaming` を返す
- 動的判定可能（例: Mermaid validator 成功時のみ `partial`）

---

## 6. ArtifactType 一覧

### 6.1 Tier 1: Claude 互換

| ArtifactType | MIME | Partial デフォルト |
|--------------|------|------------------|
| `.html` | `text/html` | incremental |
| `.react` | `application/vnd.ant.react` | requiresComplete |
| `.svg` | `image/svg+xml` | incremental |
| `.mermaid` | `application/vnd.ant.mermaid` | requiresComplete |
| `.markdown` | `text/markdown` | incremental |
| `.code` | `application/vnd.ant.code` | incremental |

### 6.2 Tier 2: 高頻度 Agent 出力

| ArtifactType | MIME | Partial デフォルト |
|--------------|------|------------------|
| `.json` | `application/json` | incremental |
| `.csv` | `text/csv` | incremental |
| `.vegaLite` | `application/vnd.vegalite.v5+json` | requiresComplete |
| `.gltf` | `model/gltf+json` | requiresComplete |
| `.glb` | `model/gltf-binary` | requiresComplete |
| `.usdz` | `model/vnd.usdz+zip` | requiresComplete |
| `.geoJSON` | `application/geo+json` | incremental |
| `.latex` | `application/x-latex` | incremental |

### 6.3 Tier 3: ユーザー定義（拡張ポイント）

ライブラリ外でユーザーが定義する。例:

- `application/vnd.stamp.itinerary+json` (Tabisaki)
- `application/vnd.bob.memory-graph+json`

---

## 7. 各 ArtifactType の Payload 仕様

Agent が `<artifact>` タグの内部に書く内容の仕様。

### 7.1 `.html`

完全な HTML ドキュメント。`<!DOCTYPE html>` から始まる。

### 7.2 `.react`

JSX ソース。`export default` で関数コンポーネントを定義する。React Hooks 使用可能。

```jsx
import React, { useState } from 'react';

export default function Counter() {
  const [count, setCount] = useState(0);
  return <div onClick={() => setCount(count + 1)}>{count}</div>;
}
```

### 7.3 `.svg`

`<svg>` ルートから始まる SVG ドキュメント。

### 7.4 `.mermaid`

Mermaid 記法のテキスト。

### 7.5 `.markdown`

CommonMark 準拠の Markdown テキスト。

### 7.6 `.code`

ソースコード文字列。`language` 属性で言語を指定:

```
<artifact type="application/vnd.ant.code" language="swift" identifier="..." title="...">
```

### 7.7 `.json`

JSON 文字列。

### 7.8 `.csv`

CSV 文字列。`hasHeader` 属性で先頭行がヘッダーかを指定。

### 7.9 `.vegaLite`

Vega-Lite v5 仕様の JSON。

### 7.10 `.gltf` / `.glb` / `.usdz`

ペイロードは **URL 文字列**。バイナリは含めない。

```
file:///var/mobile/.../model.glb
https://files.bob.app/abc.usdz
```

`autoRotate`, `cameraControls`, `environmentImage` などのオプションは属性で渡す。

### 7.11 `.geoJSON`

GeoJSON 仕様の JSON。`centerLatitude`, `centerLongitude`, `zoom` などを属性で指定可能。

### 7.12 `.latex`

LaTeX / TeX 数式ソース。`displayMode` 属性でブロック / インラインを指定。

---

## 8. パース

### 8.1 `ArtifactParser`

```swift
public enum ArtifactParser {
    /// 完成形のパース（同期）
    public static func parse(_ source: String) throws -> ArtifactMessage

    /// 単一アーティファクトのパース（タグ込み文字列）
    public static func parseOne(_ source: String) throws -> AnyArtifact
}
```

### 8.2 `ArtifactStreamParser`

ストリーミング対応の状態機械型パーサー。

```swift
public actor ArtifactStreamParser {
    public init()

    /// チャンクを受け取り、現在の ArtifactMessage を返す
    public func feed(_ chunk: String) -> ArtifactMessage

    /// 内部状態をリセット
    public func reset()
}
```

### 8.3 状態機械

```swift
enum ParserState {
    case text                                       // 散文受信中
    case inOpenTag(buffer: String)                  // <artifact... 受信中
    case inArtifact(current: AnyArtifact)           // タグ内本文蓄積中
    case inCloseTag(buffer: String, current: AnyArtifact)  // </artifact> 受信中
}
```

### 8.4 イベント API（低レベル）

より細かいストリーミング制御が必要な場合の低レベル API:

```swift
public enum ArtifactStreamEvent: Sendable {
    case text(String)
    case opened(AnyArtifact)
    case delta(id: ArtifactIdentifier, chunk: String)
    case closed(id: ArtifactIdentifier)
}

extension ArtifactStreamParser {
    public func feedEvents(_ chunk: String) -> [ArtifactStreamEvent]
}
```

---

## 9. View 層

### 9.1 `ArtifactView<R>`

単一アーティファクトを表示する Generic View。

```swift
public struct ArtifactView<R: ArtifactRenderable>: View {
    public let artifact: AnyArtifact
    public let renderer: R

    public init(_ artifact: AnyArtifact, renderer: R)

    public var body: some View {
        switch R.renderingState(for: artifact) {
        case .empty:
            EmptyView()
        case .streaming:
            ArtifactProgressView(artifact: artifact)
        case .partial, .complete:
            renderer.body(artifact: artifact)
        }
    }
}
```

### 9.2 `ArtifactCard`

`ArtifactView` を装飾する View。タイトルバー、展開/折りたたみ、コピーボタンなど。

```swift
public struct ArtifactCard<Content: View>: View {
    public init(
        artifact: AnyArtifact,
        @ViewBuilder content: () -> Content
    )
}
```

### 9.3 `ArtifactCanvas`

1 メッセージ分の `ArtifactMessage` を表示する View。

```swift
public struct ArtifactCanvas: View {
    public let message: ArtifactMessage

    public init(_ message: ArtifactMessage)
    public init(_ message: ArtifactMessage, renderArtifact: @escaping (AnyArtifact) -> AnyView)
}
```

利用者が Renderer 選択を制御する `renderArtifact` クロージャを渡せる。デフォルトでは Bob 標準の Renderer 群を使用。

### 9.4 ライフサイクル

- `ArtifactCanvas` は 1 メッセージバブル内に配置される想定
- 値型 `ArtifactMessage` を受け取るだけで、状態は自身で保持しない
- ストリーミング中は親（アプリ側）が `ArtifactMessage` を更新する
- バブルが LazyVStack でアンロードされたら View 自体が破棄される
- 重いリソース（WKWebView 等）は `onDisappear` で解放

---

## 10. 標準 Renderer

### 10.1 ネイティブ実装 (ArtifactRendererNative)

| Renderer | 対応 Type | 基盤 |
|----------|---------|------|
| `MarkdownRenderer` | `.markdown` | swift-markdown-ui |
| `CodeRenderer` | `.code` | Splash / Highlightr |
| `SVGRenderer` | `.svg` | SVGView / SwiftDraw |
| `JSONRenderer` | `.json` | OutlineGroup |
| `CSVRenderer` | `.csv` | SwiftUI Table |
| `GLTFSceneKitRenderer` | `.gltf`, `.glb` | Model3D / SceneKit |
| `USDZQuickLookRenderer` | `.usdz` | QuickLook / RealityKit |
| `GeoJSONMapKitRenderer` | `.geoJSON` | MapKit |

### 10.2 WebView 実装 (ArtifactRendererWeb)

| Renderer | 対応 Type | JS ライブラリ |
|----------|---------|------------|
| `HTMLWebViewRenderer` | `.html` | ネイティブ |
| `ReactWebViewRenderer` | `.react` | React 18 + Babel standalone |
| `MermaidWebViewRenderer` | `.mermaid` | mermaid.js |
| `VegaLiteWebViewRenderer` | `.vegaLite` | vega-embed |
| `LaTeXWebViewRenderer` | `.latex` | KaTeX |

WKWebView インスタンスは `WebViewPool` 経由で取得・解放される。

### 10.3 ロード戦略

- ネイティブ Renderer は Bob 起動時に即利用可能
- WebView 系は WKWebView 初期化のコストがあるため、初回表示時に遅延ロード
- 各 WebView 系 Renderer の JS ライブラリはシェル HTML 経由でロード、Bob バンドルに同梱（ネットワーク不要）

---

## 11. Partial レンダリング戦略

### 11.1 ArtifactRenderingState による切り分け

```swift
public enum ArtifactRenderingState {
    case empty
    case streaming   // Progress 表示
    case partial     // 中間状態でも実描画
    case complete    // 完成形描画
}
```

`ArtifactView` は `R.renderingState(for:)` の戻り値で:

- `.empty` → 何も表示しない
- `.streaming` → `ArtifactProgressView` を表示
- `.partial` / `.complete` → `renderer.body(artifact:)` を呼び出す

### 11.2 Type 別の Partial 戦略

| ArtifactType | Partial 戦略 |
|--------------|-----------|
| `.html` | ブラウザの寛容パーサーに任せる |
| `.react` | 完成までソースコードハイライト表示 → 完成後 mount |
| `.svg` | 末端タグ補完で随時描画 |
| `.mermaid` | パース成功時のみ更新、失敗時は Progress |
| `.markdown` | 受信した分を毎回フルパース |
| `.code` | 行単位でハイライト追加 |
| `.json` | partial JSON parser で部分構築 |
| `.csv` | 行単位で表示 |
| `.vegaLite` | 完成待ち |
| `.gltf`/`.glb` | URL 確定後にロード |
| `.usdz` | 同上 |
| `.geoJSON` | Feature 単位で追加描画 |
| `.latex` | KaTeX `throwOnError: false` |

### 11.3 動的判定の例: Mermaid

```swift
public struct MermaidWebViewRenderer: ArtifactRenderable {
    public static let artifactType: ArtifactType = .mermaid

    public static func renderingState(for artifact: AnyArtifact) -> ArtifactRenderingState {
        if artifact.isComplete { return .complete }
        if MermaidValidator.canParse(artifact.payload) { return .partial }
        return .streaming
    }

    public func body(artifact: AnyArtifact) -> some View { ... }
}
```

### 11.4 スロットリング

ストリーミング更新が高頻度の場合、View 更新を約 16ms (60fps) でスロットルすることを推奨。`ArtifactStreamParser` 側か、利用側で実装。

---

## 12. 拡張: Tier 3 (ユーザー定義 Renderer)

ライブラリ利用者は `ArtifactRenderable` に準拠した型を定義するだけで独自レンダラーを追加できる。Bob ライブラリ側の変更は不要。

```swift
// Tabisaki 旅程の例
public struct TabisakiItineraryRenderer: ArtifactRenderable {
    public static let artifactType: ArtifactType = "application/vnd.stamp.itinerary+json"

    public init() {}

    public func body(artifact: AnyArtifact) -> some View {
        // payload を JSON としてパースして独自 View で描画
        ItineraryView(jsonString: artifact.payload)
    }
}

// 利用
ArtifactCanvas(message) { artifact in
    switch artifact.type {
    case "application/vnd.stamp.itinerary+json":
        AnyView(ArtifactView(artifact, renderer: TabisakiItineraryRenderer()))
    default:
        AnyView(DefaultArtifactView(artifact))
    }
}
```

---

## 13. 利用例

### 13.1 完成形メッセージの表示

```swift
let rawMessage = """
これがフローチャートです。

<artifact type="application/vnd.ant.mermaid" identifier="flow1" title="フロー">
graph LR
  A --> B
  B --> C
</artifact>

以上です。
"""

let message = try ArtifactParser.parse(rawMessage)

// SwiftUI View
ArtifactCanvas(message)
```

### 13.2 ストリーミング表示

```swift
struct ChatBubble: View {
    let llmStream: AsyncStream<String>
    @State var message: ArtifactMessage = .empty
    @State var parser = ArtifactStreamParser()

    var body: some View {
        ArtifactCanvas(message)
            .task {
                for await chunk in llmStream {
                    message = await parser.feed(chunk)
                }
            }
    }
}
```

### 13.3 単一アーティファクト表示

```swift
let artifact: AnyArtifact = ...

ArtifactView(artifact).artifactRenderer(MarkdownRenderer())
```

### 13.4 カスタムレンダラー差し替え

```swift
ArtifactCanvas(message) { artifact in
    if artifact.type == .geoJSON {
        AnyView(ArtifactView(artifact, renderer: MapboxRenderer()))
    } else {
        AnyView(DefaultArtifactView(artifact))
    }
}
```

---

## 14. プラットフォーム要件

- Swift 6.2+
- iOS 26+ / iPadOS 26+ / macOS 26+
- WebView 系 Renderer: WebKit 利用可能なプラットフォームのみ

---

## 15. 命名規約

- `Artifact*`: ライブラリのコア名前空間
- `*Renderer`: `ArtifactRenderable` 準拠型のサフィックス
- `*Native` / `*WebView`: Renderer の実装基盤を示すサフィックス

---

## 16. 既知の検討事項

以下は将来検討する項目。MVP の範囲外。

- `@Artifactable` マクロによる `Artifactable` 準拠の自動生成
- `@Generable` (swift-generation) との統合パターン
- アーティファクトの全画面展開・モーダル表示
- WKWebView インスタンスの共有・プール戦略の具体実装
- Tier 3 標準セット（Tabisaki, Memory Graph, Agent Trace）
- アクセシビリティ対応
- 印刷・PDF エクスポート

---

## 付録 A: 設計判断の根拠

### A.1 なぜ enum ではなく struct + RawRepresentable か

`ArtifactType` は本質的に開かれた集合（MIME タイプ空間）。enum で網羅すると Tier 3 拡張のたびにライブラリの switch を更新する必要があり、設計原則「フラグではなくグラフ構造から導出」と矛盾する。

### A.2 なぜ `@Generable` の PartiallyGenerated パターンを採用しなかったか

`@Generable` は「LLM 出力全体が単一の JSON」を前提とする。Artifact は「散文に埋め込まれたタグ + 任意ペイロード」であり構造が異なる。Partial の粒度も「フィールド単位 Optional」ではなく「payload 文字列の増分」が本質。

### A.3 なぜ Registry を持たないか

グローバル可変状態は Swift Concurrency と相性が悪く、SwiftUI 慣習にも反する。コンパイル時に決定できる対応関係をランタイム辞書に押し出すのは設計的に不要な間接化。プロトコル準拠と型パラメータで解決する。

### A.4 なぜ Canvas が Parser を内包しないか

責務の混合。パースは値変換の純粋関数、Canvas は表示の責務。分離することでテスタビリティ・再利用性・ストリーミング対応のすべてが改善する。
