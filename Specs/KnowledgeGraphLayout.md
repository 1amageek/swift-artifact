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
| Edge-Edge port | 同じ Node 辺の port に接続される Edge 同士の最小距離 | 6 pt |
| Edge-Edge route | 関節後 / 途中 segment の Edge 同士の最小表示距離。共有 endpoint を持たない Edge の重なりを防ぐ | 14 pt |
| Node-Node horizontal | Group 外 Node 矩形同士の横方向最小距離 | 80 pt |
| Node-Node vertical | Group 外 Node 矩形同士の縦方向最小距離 | 40 pt |
| Group-internal Node-Node horizontal | 同一 Group 内 Node 矩形同士の横方向最小距離 | 40 pt |
| Group-internal Node-Node vertical | 同一 Group 内 Node 矩形同士の縦方向最小距離 | 28 pt |
| Edge-Node | Edge と endpoint ではない Node の最小距離 | 14 pt |
| Joint-Node | Edge の関節と Node 矩形の最小距離。source / target Node も対象 | 14 pt |
| Group-Node | Group outline と非member Node の最小距離 | 32 pt |
| Group-Group | Group outline 同士の最小距離 | 72 pt |

Edge-Group の最小距離は定義しない。Edge と Group は互いに干渉しないため、
Edge は Group outline を横切ってよい。

Edge 数による拡張:

| 対象 | 拡張規則 |
|---|---|
| connected Node-Node horizontal | `max(80 pt, 54 pt + (parallel edge count - 1) * 14 pt)` |
| connected Node-Node vertical | `max(40 pt, 54 pt + (parallel edge count - 1) * 14 pt)` |
| connected group-internal Node-Node horizontal | `max(40 pt, 48 pt + (parallel edge count - 1) * 14 pt)` |
| connected group-internal Node-Node vertical | `max(28 pt, 36 pt + (parallel edge count - 1) * 14 pt)` |
| Group-Node | `32 pt` を下限にし、compaction unit 間の Edge 数に応じて余白を追加できる |
| Group-Group | `72 pt + min(edge count, 6) * 14 pt` |

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
複数 Edge が同じ source / target Node の同じ辺へ接続する場合、その endpoint 側の port 群は
Node 中心を基準に対称配置する。side が決まった後の複数 port bundle では、この等間隔 slot を
先に固定し、その slot を endpoint として最短 route を選ぶ。
入力 Edge と出力 Edge は別 bucket に分けない。同じ Node の同じ辺に接続されるなら、
source / target の向きに関係なく同じ port bundle として分散する。
偶数本の bundle では中央そのものに port を置かず、中央を挟む 2 つの slot を使う。
この場合、直線 Edge も中央ぴったりではなく中央に最も近い slot を使い、bundle 全体の中心を
Node 辺の中心へ合わせる。
Node 同士を水平または垂直の直線で結べる Edge は、その辺の中心 port を優先して維持する。
同じ辺に関節付き Edge が混在する場合は、直線 Edge ではなく関節付き Edge 側の port / lane をずらす。
共有していない endpoint は、その Node 辺の中央 port を基準にする。ただし反対側 endpoint が
共有 port bundle 上にあり、その bundle slot に合わせることで交差を増やさず直線 route にできる場合は、
singleton endpoint を同じ axis へ寄せてよい。
両 endpoint が共有 port bundle 上にある場合も、直線 route の候補 axis を全て評価し、
関節付き route より短くできるなら中央 bias より直線を優先する。
分散 port のままだと中間 Node を避けるために大きな迂回が必要になる場合は、他辺の中央 port も
候補に含め、最短 route を優先する。

| 条件 | 配置規則 |
|---|---|
| `Edge-Edge port * (port数 - 1) <= Node辺長` | 隣接 port 間を Edge-Edge port 距離にする |
| `Edge-Edge port * (port数 - 1) > Node辺長` | Edge-Edge port 距離を緩和し、Node辺内で隣接距離が均等になるよう縮める |

```text
Edge-Edge port 距離が収まる場合

      p0   p1   p2
┌─────┬────┬────┬─────┐
│          Node        │
└──────────────────────┘

Edge-Edge port 距離が収まらない場合

 p0  p1  p2  p3  p4
┌┬───┬───┬───┬───┬┐
│        Node        │
└────────────────────┘

偶数本 bundle の中央 bias

NG: direct を 0 に固定し、残りが片側へ偏る
       -1   0   +1  +2
┌──────┬────┬────┬────┬──┐
│             Node        │
└─────────────────────────┘

OK: bundle 全体の中心を Node 中心へ合わせる
      -1.5 -0.5 +0.5 +1.5
┌───────┬────┬────┬────┬────┐
│              Node          │
└────────────────────────────┘
```

実装では角の side 判定が曖昧にならないよう、Port は 1 pt の corner guard を残して辺内に収める。
複数 port の bundle では、同じ Node/side 上の port slot を先に等間隔で確定する。
その後、各 Edge はその port slot を endpoint として最短 route を選ぶ。個別 Edge が少し短くなることを理由に、
1 本だけ古い port 位置を残して bundle の等間隔を崩してはならない。
単一 port endpoint の中央 bias だけは、既存 route が `Edge-Edge port + 2.5 pt` を超えて伸びる場合に採用しない。
これは、bundle 制約が存在しない場合は中央寄せよりも Edge 最短を優先するためである。

### 3.4 経路優先順位

Edge route は以下の順に選ぶ。

| 優先 | 条件 | 説明 |
|---:|---|---|
| 1 | 角 0 | 水平または垂直の直線。Node に干渉しない場合はこれが最短 |
| 2 | Node 非干渉 | endpoint 以外の Node に干渉する候補は採用しない |
| 3 | Joint-Node 非干渉 | source / target を含む Node の近くに関節を置く候補は採用しない |
| 4 | 最短 Edge 長 | 斜めが必要に見える場合は、角 1 / 角 2 / 角 3+ の候補から Edge 長が短いものを優先 |
| 5 | 角数 | Edge 長が同程度なら、角が少ない候補を優先 |
| 6 | Port 中央 bias | Edge 長と角数が同程度の場合だけ、preferred port / 中央寄り port を優先 |
| 7 | Edge-Edge 視認性 | 角数と長さが同程度の場合だけ、既存 Edge との距離が広い候補を優先 |
| 8 | 多角迂回 | Node を避けるために必要な場合のみ角を増やす |

Node に被る候補は、Edge 長が短くても採用しない。
関節が Node に近すぎる候補も採用しない。これは endpoint Node も対象であり、
port 接続直後に短い折れ曲がりを作って Node に密着させてはならない。

実装は重み付き合算スコアで route を選ばない。
次の辞書式順序で候補を比較する。

```text
1. endpoint が Node 辺に法線接続している
2. endpoint 以外の Node を避けている
3. 関節が source / target を含む Node から Joint-Node 距離以上離れている
4. Edge 長が短い。Edge-Edge の視認性 penalty を Edge 長へ加算してはならない
5. 角数が少ない
6. preferred port / Node 辺中央 bias に近い
7. Edge-Edge の視認性が高い
```

共有 endpoint を持つ Edge でも、endpoint 直後の fan-out 区間を過ぎた後は Edge-Edge route 距離を満たす。
endpoint 直後の fan-out 区間だけは Port 配置ルールに従う。これは Node 辺長が不足する場合に
Port 間隔を Edge-Edge port 距離まで圧縮できるようにするためである。
共有 endpoint を持つ Edge 同士では、fan-out 後の近接は port 配置を壊さない範囲で弱い penalty として扱う。
共有 endpoint を持たない Edge 同士では、Edge-Edge 距離違反を強い penalty として扱い、
関節付き Edge の途中 segment でも重なりや交差を避ける。

```text
endpoint fan-out: Port ルールに任せる
Node ─┬─ Edge A
      └─ Edge B

関節後の lane: Edge-Edge route 距離を満たす
Edge A ─┐    ┌─
        │    │  >= Edge-Edge route
Edge B ─┘    └─
```

単一 Edge endpoint の port は単一候補に固定しない。各 Node 辺の中央 port 候補を列挙し、
上記の順序で route を選ぶ。Edge 長が短い候補と preferred port に近い候補が競合する場合は、
必ず Edge 長が短い候補を選ぶ。
直線 route が成立する場合、同じ endpoint side に他の関節付き Edge があっても、
直線 route は維持する。偶数本 bundle では直線 Edge を絶対中央に固定せず、bundle 全体の中心を
保てる中央近傍 slot を使う。反対側 endpoint が単一 port の場合は、その endpoint も同じ axis へ
寄せて直線 route を維持する。

同じ Node 辺に複数 Edge が入る endpoint でも、分散済み port だけを固定候補にしてはならない。
反対側 endpoint が共有されていない場合は反対側 Node 辺の中央 port を維持する。
直線 route が中間 Node に被る場合、または中央 port 同士が同一直線上にない場合は、
分散済み port と他辺の中央 port を比較し、最短の orthogonal route を選ぶ。
port の近さは、route 長と角数が同等の場合の tie-break とする。

固定 endpoint 間に Node / Edge 干渉のない Manhattan L route が存在する場合、route 長は
その endpoint 間の Manhattan 距離を超えてはならない。

初期 route 確定後、同じ Node の同じ辺に複数 port がある場合は、port 割り当ての swap を試してよい。
swap は対象 Edge 群をまとめて評価し、局所的な直線化だけで他 Edge を伸ばしたり交差させたりしてはならない。

| port assignment 優先 | 評価軸 | 説明 |
|---:|---|---|
| 1 | Edge 交差数 | swap によって交差が増える候補は採用しない |
| 2 | 合計 route 長 | 対象 Edge 群の合計長が短い候補を優先する |
| 3 | 最大個別 route 長 | 合計長が同等なら、1 本だけ長くなる割り当てを避ける |
| 4 | 合計関節数 | 距離と交差が同等の場合にだけ、関節数が少ない候補を優先する |
| 5 | Edge-Edge 視認性 | 最後に途中 segment の近接 penalty を比較する |

port swap 後の直線化 pass は、片側だけが共有 bundle の Edge に限定しない。
両 endpoint が共有 bundle 上にある場合でも、中央 bias 候補、source port 候補、target port 候補、
overlap center 候補をすべて評価し、交差を増やさず route 長を伸ばさずに関節数または route 長を
改善できる直線 route を採用する。最初に見つかった中央 bias 候補だけで探索を打ち切ってはならない。
direct align 後に port bundle の spacing が崩れる場合は、endpoint bundle を再分散し、
port assignment と direct align を再評価する。直線化は Edge-Edge port 距離を破ってはならない。
この swap / 直線化評価は、変更される Edge と近傍 segment だけを比較する差分評価で行う。
全 Edge ペアを毎回再評価してはならない。

衝突判定は Node rect / Edge segment の空間 index を通して行う。
route 候補は近傍 Node / 近傍 segment だけを検査対象にするが、判定結果は全探索と同じでなければならない。
index は探索高速化のための実装詳細であり、上記の最短 route / 非干渉 / Edge-Edge 距離制約を弱めてはならない。
index は pass / iteration ごとに再利用し、Edge 単位の全 segment index 再構築や全ペア再評価を避ける。
hot path の近傍判定は必要な時だけ callback 走査し、route / node / segment の中間配列を作ってから再走査してはならない。
障害物迂回探索は route 長、角数の順で優先される Dijkstra 探索として扱い、未訪問候補の全走査ではなく優先度 queue で最短候補から展開する。

探索は以下の順序で構成する。

| 段階 | 目的 | 必須条件 |
|---|---|---|
| port 候補列挙 | Node 辺中央と分散 port の両方を候補に残す | 中央 port が使える場合は最短 route で勝てること |
| route 候補列挙 | 直線、1角、2角、障害物迂回を比較する | Node 非干渉を満たす全候補で route 長を最優先に採点すること |
| 空間 index 判定 | Node rect と既存 Edge segment の近傍だけを検査する | 全探索と同じ違反を検出すること |
| port swap 差分評価 | 交差を増やさず route 長と最大個別長を最小化する | 変更 Edge と近傍 segment だけを評価し、最良改善を採用すること |
| direct 直線化 | 共有 / singleton endpoint の直線候補 axis を全て比較する | 交差を増やさず route 長を伸ばさずに直線化できる場合だけ採用すること |
| 同長関節 lane 正規化 | H-V-H / V-H-V の関節を同じ route 長の範囲でスライドする | 法線接続、Node 非干渉、Edge-Edge 距離を保ったまま、区間占有と 14pt lane rhythm に揃えること |

```text
port candidates -> shortest valid route -> nearby collision check -> local port swap -> direct align -> redistribute -> direct align -> equal-length lane normalize
       │                    │                         │                    │               │              │
       └──── keeps center   └──── length first        └──── exact result   └──── no cross  └──── ports    └──── no length growth
```

同長関節 lane 正規化では、縦 / 横の中間 segment を単独で評価しない。
各候補 axis について、その segment が占有する区間と近傍 segment の区間 overlap 長を集計し、
同じ区間を長く並走する候補ほど強く penalty を与える。これは差分配列 / imos 法の考え方と同じで、
「どの y 区間または x 区間に Edge が集中しているか」を先に見てから lane を選ぶ。

```text
axis A:  y  60 ───────── 180     load: 2
axis B:  y       100 ─── 150     load: 3  <- avoid
axis C:  y  60 ───────── 180     load: 1  <- prefer
```

同じ pass 内で選んだ lane は直ちに segment index へ反映する。
古い index を見たまま全 Edge が同じ空き lane を選ぶ batch 更新は禁止する。
segment index は pass 開始時に構築し、lane が実際に動いた時は対象 Edge の segment だけを差し替える。
Edge ごとの候補評価、または単一 Edge の lane 更新のたびに全 route segment index を作り直してはならない。
現行 route が Joint-Node / Node 非干渉を満たしていない場合は、現行 route を無条件の基準として残してはならない。

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
この場合は Edge-Edge route 距離と label 表示余白を満たすため、単一 Edge の最短経路より長くなってよい。
ただし、port 分散だけを理由に明らかに長い外周迂回を選んではならない。Node 非干渉を満たす
短い side-port route がある場合は、そちらを優先する。

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
複数関節を持つ Edge では、label center は source / output port から数えて 2 本目の直線 segment 上に置く。
既定位置はその segment の中心であり、他 label と近接する場合だけ同じ segment 上で反発してずらす。
Edge label 間の最小距離は 4 pt とする。

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
Node は横長になりやすいため、Group 外では横方向の Node-Node 距離を縦方向より広く取る。
縦方向は既存の密度を維持し、横方向だけ広げる。

Group 内では、Node が横長であることを前提に、基本は縦積みを優先する。
Group 内で Node 同士が密に接続されるケースより、Group 外の Node と接続されるケースの方が多いためである。
Group 内の Node-Node 距離は Group 外より小さくし、Group outline が不必要に膨らまないようにする。

Group を内部 layout block に分解する場合、block 間距離には Group padding を含めない。
Group padding は最終的な Group outline の描画時にだけ加算する。
これにより、共有 member を持つ Group で同一 Group 内の Edge が block 境界をまたいでも、
padding が Node-Node 距離として二重に加算されない。

### 4.2 Group

Group は member Node を含む outline として扱う。
Group outline は Group-Group / Group-Node 最小距離を満たす。
Group と Edge は干渉しないため、Edge は Group outline を横切ってよい。

### 4.3 全体 outline 最小化

Edge / Node / Group の最小距離と Edge の最短性を満たした後、global layout elements を囲む
outline 面積を最小化する。

global layout elements は次だけである。

| 要素 | global outline 対象 |
|---|---|
| Outermost Group | 対象。ほかの Group の strict subset ではない Group |
| Nested Group | 対象外。外側の Outermost Group の内側要素として扱う |
| Ungrouped Node | 対象。どの Group にも所属しない Node |
| Group member Node | 対象外。所属する Outermost Group の outline に含める |

Nested Group 同士の距離は親 Group 内の内部制約として扱い、外側の Group-Group 距離計算には使わない。
直下の Nested Group sibling は親 Group header 下端から `14 pt` の位置へ top alignment し、
sibling 間も `14 pt` 以上離す。
親 Group の直下要素に Nested Group と direct member Node が混在する場合は、
それらの直下要素を同じ internal packing unit として扱う。
直下Nodeだけで、Group内の内部Edgeがない場合は、Nodeを縦方向へ詰め直す候補も評価する。
内部 packing は Group-Group / Group-Node / Group 内 Node-Node の最小距離を満たす範囲で
親 Group の content outline 面積を最小化し、遠くに残った Node によって親 Group が不必要に膨らむ状態を許可しない。

```text
優先順位

1. 干渉しない
2. 必要な最小距離を満たす
3. global layout elements 全体の外接面積を小さくする
4. Edge を短くする
5. Edge 長が同程度なら角数を少なくする
```

実装上の保証:

```text
距離制約投影
  ↓
各 Group の直下要素（Nested Group / direct Node）を internal packing unit に変換
  ↓
Group 内 content outline を MaxRects + 候補幅探索で最小化
  ↓
Outermost Group / Ungrouped Node を compaction unit に変換
  ↓
現在の分離軸（X/Y）による longest-path compaction 候補を作る
  ↓
ネストした outermost Group layout では MaxRects + 候補幅探索で packing 候補を列挙する
  ↓
outline 面積が最小の候補を採用する
  ↓
距離制約を再投影
```

MaxRects packing では全 pair の最小距離要求の最大値を item gap として使う。
候補幅は `max item width`、`sqrt(total area)` 近傍、各 order の累積幅、`sum item width` から列挙する。
これにより、2 つの outermost Group は横並びまたは縦並びのどちらか小さい方になり、
3 つ以上では固定幅ごとの 2D rectangle packing 候補から global outline 面積が最小のものを選ぶ。

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

Edge label は Edge 全体の中央固定にしない。
複数関節を持つ Edge では、source / output port から数えて 2 本目の直線 segment を優先する。
中央で Node / 他 label と重なりやすい場合があるため、単一 segment 上での反発移動を許可する。
Label の中心は必ず Edge の経路上に置く。
Label の位置をずらせる方向は Edge に沿った接線方向だけであり、Edge から法線方向へ逃がしてはならない。

```text
source ──┐
         ├── [2nd segment center] ──┐
         │                           └── target
```

Label は Node と重ならない位置を優先する。
ただし、Label が Edge から離れすぎてはならない。
Edge label 同士の最小距離は 4 pt とし、重なる場合は同じ直線 segment 上で候補をずらして解消する。

Label 候補は次の順で比較する。

| 優先 | 条件 |
|---:|---|
| 1 | 複数関節 Edge では source から 2 本目の直線 segment 上にある |
| 2 | Node / 既存 label との衝突面積が小さい |
| 3 | 2 本目 segment 中心に近い |

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
| L5 | Edge-Edge port / Edge-Edge route / Node-Node / Edge-Node / Joint-Node / Group-Node / Group-Group の最小距離を持つ |
| L6 | Edge-Group 距離は持たない |
| L7 | 複数 Edge の場合は表示余白を優先し、単一 Edge より長くなってよい |
| L8 | 上記制約を満たした後、全体 outline 面積を最小化する |
