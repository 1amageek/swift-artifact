import CoreGraphics

struct KnowledgeGraphLayoutCompactionUnit {
    let groupIndices: Set<Int>
    let indices: [Int]
    let memberSet: Set<Int>
    let rect: CGRect
}

struct KnowledgeGraphNodeNodeGap {
    let horizontal: CGFloat
    let vertical: CGFloat
}
