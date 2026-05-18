import Foundation
import KnowledgeGraph

enum JSONLDViewGroupExtractor {

    static func groupingStrategy(from payload: String) -> GroupingStrategy? {
        guard let groups = explicitGroups(from: payload), !groups.isEmpty else {
            return nil
        }
        return .explicit(groups: groups)
    }

    static func explicitGroups(from payload: String) -> [GroupingStrategy.ExplicitGroup]? {
        guard let data = payload.data(using: .utf8) else {
            return nil
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        guard let root = object as? [String: Any],
              let view = root["view"] as? [String: Any],
              let groups = view["groups"] as? [[String: Any]]
        else { return nil }
        let resolver = IdentifierResolver(context: root["@context"])
        var result: [GroupingStrategy.ExplicitGroup] = []
        for group in groups {
            appendGroup(group, resolver: resolver, result: &result)
        }
        return result
    }

    @discardableResult
    private static func appendGroup(
        _ group: [String: Any],
        resolver: IdentifierResolver,
        result: inout [GroupingStrategy.ExplicitGroup]
    ) -> [NodeIdentifier] {
        guard let id = group["id"] as? String,
              let title = group["title"] as? String,
              !id.isEmpty,
              !title.isEmpty
        else {
            return []
        }
        let insertionIndex = result.count
        var memberIDs = parseMembers(group["members"], resolver: resolver)
        if let children = group["children"] as? [[String: Any]] {
            for child in children {
                memberIDs.append(contentsOf: appendGroup(
                    child,
                    resolver: resolver,
                    result: &result
                ))
            }
        }
        memberIDs = deduplicated(memberIDs)
        if !memberIDs.isEmpty {
            result.insert(GroupingStrategy.ExplicitGroup(
                id: id,
                label: title,
                memberNodeIDs: memberIDs
            ), at: insertionIndex)
        }
        return memberIDs
    }

    private static func parseMembers(
        _ value: Any?,
        resolver: IdentifierResolver
    ) -> [NodeIdentifier] {
        guard let members = value as? [Any] else { return [] }
        return members.compactMap { item in
            if let id = item as? String {
                return resolver.resolve(id)
            }
            if let object = item as? [String: Any],
               let id = object["@id"] as? String {
                return resolver.resolve(id)
            }
            return nil
        }
    }

    private static func deduplicated(_ members: [NodeIdentifier]) -> [NodeIdentifier] {
        var result: [NodeIdentifier] = []
        var seen: Set<NodeIdentifier> = []
        for member in members where seen.insert(member).inserted {
            result.append(member)
        }
        return result
    }

    struct IdentifierResolver {
        let prefixes: [String: String]

        init(context: Any?) {
            self.prefixes = Self.collectPrefixes(from: context)
        }

        func resolve(_ id: String) -> NodeIdentifier? {
            guard !id.isEmpty else { return nil }
            if id.hasPrefix("_:") {
                return .blank(String(id.dropFirst(2)))
            }
            if id.hasPrefix("http://") || id.hasPrefix("https://") || id.hasPrefix("urn:") {
                return .iri(id)
            }
            guard let colon = id.firstIndex(of: ":") else {
                return nil
            }
            let prefix = String(id[..<colon])
            let suffix = String(id[id.index(after: colon)...])
            guard let base = prefixes[prefix] else {
                return nil
            }
            return .iri(base + suffix)
        }

        private static func collectPrefixes(from context: Any?) -> [String: String] {
            var result: [String: String] = [:]
            collectPrefixes(from: context, into: &result)
            return result
        }

        private static func collectPrefixes(from context: Any?, into result: inout [String: String]) {
            if let array = context as? [Any] {
                for item in array {
                    collectPrefixes(from: item, into: &result)
                }
                return
            }
            guard let dictionary = context as? [String: Any] else { return }
            for (key, value) in dictionary {
                if let iri = value as? String,
                   iri.hasSuffix("#") || iri.hasSuffix("/") || iri.hasSuffix(":") {
                    result[key] = iri
                }
            }
        }
    }
}
