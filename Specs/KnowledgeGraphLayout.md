# Knowledge Graph Layout — Constraint Spec

この文書は `KnowledgeGraphLayout` が満たすべき基本制約を定義する。
Grouping の見た目ではなく、Node / Edge / Group の幾何制約そのものを扱う。

---

## 1. 基本方針

レイアウトは、次の順序で制約を満たす。

```text
入力 graph
  ↓
Node / Group の最小距離を確保
  ↓
Edge が表示できる余白を確保
  ↓
Node / Group を囲む全体 outline 面積を最小化
  ↓
Edge を最短の orthogonal route で接続
  ↓
Canvas 上へ描画
```

最重要ルール:

- Edge は基本的に最短距離を通る経路である。
- ただし、同じ endpoint 周辺に Edge が複数ある場合は、Edge 同士を表示できる余白を確保するために経路が伸びてよい。
- Node と Group の距離も同様に最小距離を持つ。
- 距離が伸びる主因は Edge 数であり、Edge / Edge label / endpoint port を十分に表示するための余白である。
- 上記の距離制約を満たした後、Node と Group を囲む全体 outline の面積を最小化する。

---

## 2. 最小距離

| 制約 | 意味 | 初期値 |
|---|---|---:|
| Edge-Edge | Edge 同士の最小表示距離。共有 endpoint を持たない Edge の重なりを防ぐ | 18 pt |
| Node-Node | Node 矩形同士の最小距離 | 40 pt |
| Edge-Node | Edge と endpoint ではない Node の最小距離 | 18 pt |
| Group-Node | Group outline と非member Node の最小距離 | 32 pt |
| Group-Group | Group outline 同士の最小距離 | 72 pt |

Edge-Group の最小距離は定義しない。Edge と Group は互いに干渉しないため、
Edge は Group outline を横切ってよい。

Edge 数による拡張:

| 対象 | 拡張規則 |
|---|---|
| connected Node-Node | `max(40 pt, 54 pt + (parallel edge count - 1) * 18 pt)` |
| Group-Node | `32 pt` を下限にし、compaction unit 間の Edge 数に応じて余白を追加できる |
| Group-Group | `72 pt + min(edge count, 6) * 18 pt` |

この拡張は余白を増やすためのものだが、余白を増やした後はその値を新しい最小距離として扱う。

---

## 3. Edge Routing

### 3.1 斜め禁止

Edge segment は水平または垂直のみで構成する。

```text
OK
Node ───────── Node

OK
Node ──┐
       └──── Node

NG
Node ╲
      ╲ Node
```

斜め線が必要に見える位置関係では、斜め線を使わず、角を持つ orthogonal route を使う。

### 3.2 Node への接続

Edge は Node の辺に対して常に法線方向で接続する。

```text
OK
┌──── Node ────┐
│              │
└──────┬───────┘
       │

NG
┌──── Node ────┐
│              │
└──────────────┘╲
```

### 3.3 Port 配置

Port は Node 辺上の中央を基準に配置する。ただし、これは route 選択の最上位条件ではない。
Node / Edge の干渉がなく、辺上の別位置を使うことで直線またはより短い経路にできる場合は、
Edge 最短を優先する。

```text
単一 Edge

┌──────── Node ────────┐
│                      │
└──────────┬───────────┘
           │
```

同じ Node の同じ辺に 2 本以上の Edge が接続する場合は、Port 群全体を辺中央に揃えたまま分散する。
この分散は Edge-Edge の視認性を上げるための preferred placement であり、干渉のない直線最短経路より
優先してはならない。

| 条件 | 配置規則 |
|---|---|
| `Edge-Edge最小距離 * (port数 - 1) <= Node辺長` | 隣接 port 間を Edge-Edge 最小距離にする |
| `Edge-Edge最小距離 * (port数 - 1) > Node辺長` | Edge-Edge 最小距離を緩和し、Node辺内で隣接距離が均等になるよう縮める |

```text
Edge-Edge 距離が収まる場合

      p0   p1   p2
┌─────┬────┬────┬─────┐
│          Node        │
└──────────────────────┘

Edge-Edge 距離が収まらない場合

 p0  p1  p2  p3  p4
┌┬───┬───┬───┬───┬┐
│        Node        │
└────────────────────┘
```

実装では角の side 判定が曖昧にならないよう、Port は 1 pt の corner guard を残して辺内に収める。

### 3.4 経路優先順位

Edge route は以下の順に選ぶ。

| 優先 | 条件 | 説明 |
|---:|---|---|
| 1 | 角 0 | 水平または垂直の直線。Node / Edge に干渉しない場合はこれが最短 |
| 2 | Node / Edge 非干渉 | endpoint 以外の Node と、endpoint fan-out 以外の Edge に干渉する候補は採用しない |
| 3 | 最短 Edge 長 | 斜めが必要に見える場合は、角 1 / 角 2 / 角 3+ の候補から Edge 長が短いものを優先 |
| 4 | 角数 | Edge 長が同程度なら、角が少ない候補を優先 |
| 5 | 多角迂回 | Node を避けるために必要な場合のみ角を増やす |

Node に被る候補は、Edge 長が短くても採用しない。

実装は重み付き合算スコアで route を選ばない。
次の辞書式順序で候補を比較する。

```text
1. endpoint が Node 辺に法線接続している
2. endpoint 以外の Node を避けている
3. 既存 Edge との Edge-Edge 距離を満たしている
4. Edge 長が短い
5. 角数が少ない
6. preferred port に近い
```

共有 endpoint を持つ Edge でも、endpoint 直後の fan-out 区間を過ぎた後は Edge-Edge 距離を満たす。
endpoint 直後の fan-out 区間だけは Port 配置ルールに従う。これは Node 辺長が不足する場合に
Port 間隔を圧縮できるようにするためである。
共有 endpoint を持つ Edge 同士では、fan-out 後の近接は port 配置を壊さない範囲で許容できるが、
実際の重なりや交差は避ける。

```text
endpoint fan-out: Port ルールに任せる
Node ─┬─ Edge A
      └─ Edge B

関節後の lane: Edge-Edge 距離を満たす
Edge A ─┐    ┌─
        │    │  >= Edge-Edge
Edge B ─┘    └─
```

port も単一候補に固定しない。各 Node 辺の中央 port 候補を列挙し、上記の順序で route を選ぶ。
同じ Node 辺に複数 Edge が入る場合でも、分散済み port は固定制約ではなく preferred port として扱う。
Edge 長が短い候補と preferred port に近い候補が競合する場合は、必ず Edge 長が短い候補を選ぶ。

固定 endpoint 間に Node / Edge 干渉のない Manhattan L route が存在する場合、route 長は
その endpoint 間の Manhattan 距離を超えてはならない。

### 3.5 Node と Edge の干渉

Edge は endpoint ではない Node に被ってはならない。

```text
NG
Node A ─────── Node B
          │
       Node C

OK
Node A ──┐
         │
         └──── Node B
       Node C
```

Node に被る場合は、角を増やして迂回する。
この時、角数増加よりも Node 非干渉を優先する。

### 3.6 複数 Edge

同じ Node 周辺に複数 Edge がある場合は、port を分散する。
この場合は Edge-Edge 最小距離と label 表示余白を満たすため、単一 Edge の最短経路より長くなってよい。

```text
Node ── Edge 1
Node ── Edge 2
Node ── Edge 3
```

### 3.7 Edge label と接続点の視認性

Edge label は Edge の中心線上に置くが、label pill が Edge を視覚的に分断してはならない。
label pill の中央には、その label が属する route の向きに沿った guide line を描く。
これにより、同じ predicate label が複数並んでも、label がどの Edge に属するかを追跡できる。
また、label pill は他の Edge route を横切る位置を避ける。避けられない場合でも、
label center は必ず自分の Edge route 上に残す。

```text
OK
Node ───[ knows ]─── Node
          ─────

NG
Node ───[ knows ]   Node
        pill が線を隠し、Edge が途切れて見える

NG
Edge A ───[ knows ]───
             │
             │ Edge B が他 Edge label を横切る
```

Edge の source 側にも小さな terminal marker を表示する。
target 側は arrowhead を表示する。
これにより、Edge がどの Node boundary port から出て、どの Node boundary port に入るかを確認できる。

```text
source marker        target arrowhead
      ● ───────────────▶
```

---

## 4. Node / Group 配置

### 4.1 Node

Node は Node-Node 最小距離を満たす。
Node 間距離は、接続 Edge 数が増えて port / label / route の表示余白が必要な場合だけ増やす。

Group 内では、Node が横長であることを前提に、基本は縦積みを優先する。
Group 内で Node 同士が密に接続されるケースより、Group 外の Node と接続されるケースの方が多いためである。

### 4.2 Group

Group は member Node を含む outline として扱う。
Group outline は Group-Group / Group-Node 最小距離を満たす。
Group と Edge は干渉しないため、Edge は Group outline を横切ってよい。

### 4.3 全体 outline 最小化

Edge / Node / Group の最小距離を満たした後、すべての Node と Group を囲む
outline 面積を最小化する。

```text
優先順位

1. 干渉しない
2. 必要な最小距離を満たす
3. Group / Node 全体の外接面積を小さくする
4. Edge を短くする
5. Edge 長が同程度なら角数を少なくする
```

実装上の保証:

```text
距離制約投影
  ↓
Group overlap component を compaction unit に変換
  ↓
現在の分離軸（X/Y）を固定
  ↓
X / Y それぞれを longest-path compaction で最小化
  ↓
距離制約を再投影
```

このため、crossing reduction で決まった相対順序と、現在の X/Y 分離軸を固定した範囲では、
全体 outline の幅と高さはそれ以上縮められない状態になる。

Group が member Node を共有する場合は、別々の compaction unit に分けない。
共有 member を持つ Group 群は 1 つの overlap component として扱い、bridge group の endpoint を
無理に引き離さない。

未グループの rank layout では、rank を横一列に固定しない。
連続 rank を band に分割する候補を列挙し、各候補について次の順で比較する。

| 優先 | 条件 |
|---:|---|
| 1 | outline aspect が `0.95...2.05` に入る |
| 2 | Node outline 面積が小さい |
| 3 | aspect が `3:2` に近い |
| 4 | band 数が少ない |

```text
NG: rank を横一列に固定
Node ─ Node ─ Node ─ Node ─ Node ─ Node

OK: outline 面積と aspect を比較して band 化
Node ─ Node
   │
Node ─ Node
   │
Node ─ Node
```

---

## 5. Edge Label

Edge label は Edge 上の中央固定にしない。
中央で Node / 他 label と重なりやすい場合があるため、Edge 上の偏った位置を優先候補にする。
Label の中心は必ず Edge の経路上に置く。
Label の位置をずらせる方向は Edge に沿った接線方向だけであり、Edge から法線方向へ逃がしてはならない。

```text
Node ─── [38%] ─── 50% ─── [62%] ─── Node
```

Label は Node と重ならない位置を優先する。
ただし、Label が Edge から離れすぎてはならない。

Label 候補は次の順で比較する。

| 優先 | 条件 |
|---:|---|
| 1 | Node / 既存 label との衝突面積が小さい |
| 2 | 38% / 62% などの優先サンプル順 |

```text
許可:  Edge ─── [label center] ─── Edge
禁止:  Edge ────┐
                 └─ [label center]
```

Edge label の矩形は最終 canvas bounds に含める。
そのため、外周迂回 Edge の label が canvas 端で切れたり、見かけ上 Edge から離れすぎたりしてはならない。

---

## 6. 実装上の不変条件

| ID | 条件 |
|---|---|
| L1 | Edge segment は水平または垂直のみ |
| L2 | Edge は source / target Node の辺に法線方向で接続 |
| L3 | Edge は endpoint ではない Node に被らない |
| L4 | Edge route は制約を満たす候補の中で Edge 長を優先し、同程度なら角数を少なくする |
| L5 | Edge-Edge / Node-Node / Edge-Node / Group-Node / Group-Group の最小距離を持つ |
| L6 | Edge-Group 距離は持たない |
| L7 | 複数 Edge の場合は表示余白を優先し、単一 Edge より長くなってよい |
| L8 | 上記制約を満たした後、全体 outline 面積を最小化する |
