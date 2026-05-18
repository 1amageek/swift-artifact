import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Spreadsheet-style rendering of parsed CSV rows.
///
/// Design points:
///
/// - **Width fills the container**: each column uses `frame(maxWidth:
///   .infinity)`, so the row spreads to occupy whatever horizontal space
///   the host provides (the card, in practice). Columns share width
///   equally; the responsibility of capping width for very wide tables
///   sits with the host.
/// - **Height is parent-bounded**: `CSVRenderer` wraps the table in a
///   scroll view and applies the artifact content height limit so large
///   tables do not force ancestor split views or inspectors to grow.
/// - **Sticky header**: pinned via `LazyVStack` + `pinnedViews`. The pin
///   only activates if the host adds vertical scrolling above us.
/// - **Type-aware alignment**: columns where every non-empty value parses
///   as `Double` are right-aligned with monospaced digits.
/// - **Zebra striping**: alternating rows use a subtle tint so dense
///   tables stay readable.
/// - **Selectable cells**: text selection is inherited from the enclosing
///   `ArtifactView`. Per-row context menus add "Copy row" and the table
///   itself offers "Copy as CSV / TSV".
struct CSVTableView: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        let headerCount = header.count
        let bodyMax = rows.map(\.count).max() ?? 0
        return max(headerCount, bodyMax)
    }

    private var columnTypes: [CSVColumnType] {
        CSVColumnAnalysis.inferTypes(rows: rows, columnCount: columnCount)
    }

    var body: some View {
        if header.isEmpty && rows.isEmpty {
            ContentUnavailableView("No rows", systemImage: "tablecells")
                .frame(maxWidth: .infinity, minHeight: 80)
        } else {
            LazyVStack(
                spacing: 0,
                pinnedViews: header.isEmpty ? [] : [.sectionHeaders]
            ) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        rowView(row: row, striped: !index.isMultiple(of: 2))
                    }
                } header: {
                    if !header.isEmpty {
                        headerRow
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .contextMenu {
                Button {
                    CSVPasteboard.copy(rows: allRowsIncludingHeader, separator: ",")
                } label: {
                    Label("Copy as CSV", systemImage: "doc.on.doc")
                }
                Button {
                    CSVPasteboard.copy(rows: allRowsIncludingHeader, separator: "\t")
                } label: {
                    Label("Copy as TSV", systemImage: "tablecells")
                }
            }
        }
    }

    private var allRowsIncludingHeader: [[String]] {
        header.isEmpty ? rows : ([header] + rows)
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { i in
                Text(i < header.count ? header[i] : "")
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: alignment(for: i))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
        }
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func rowView(row: [String], striped: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { i in
                let cell = i < row.count ? row[i] : ""
                let isNumeric = i < columnTypes.count && columnTypes[i] == .numeric
                Text(cell)
                    .font(isNumeric ? .callout.monospacedDigit() : .callout)
                    .frame(maxWidth: .infinity, alignment: alignment(for: i))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
            }
        }
        .background(striped ? Color.secondary.opacity(0.06) : Color.clear)
        .contextMenu {
            Button {
                CSVPasteboard.copy(row: row, separator: ",")
            } label: {
                Label("Copy row", systemImage: "doc.on.doc")
            }
        }
    }

    private func alignment(for column: Int) -> Alignment {
        guard column < columnTypes.count else { return .leading }
        return columnTypes[column] == .numeric ? .trailing : .leading
    }
}

enum CSVColumnType: Sendable, Equatable {
    case text
    case numeric
}

enum CSVColumnAnalysis {
    /// Returns one type per column. A column is `.numeric` iff every
    /// non-empty cell in the body parses as `Double`. An empty column
    /// (all cells blank) falls back to `.text`.
    static func inferTypes(rows: [[String]], columnCount: Int) -> [CSVColumnType] {
        guard columnCount > 0 else { return [] }
        var types = Array(repeating: CSVColumnType.numeric, count: columnCount)
        var hasAnyValue = Array(repeating: false, count: columnCount)
        for row in rows {
            for i in 0..<min(row.count, columnCount) {
                let trimmed = row[i].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                hasAnyValue[i] = true
                if types[i] == .numeric, Double(trimmed) == nil {
                    types[i] = .text
                }
            }
        }
        // Columns with no observed values default to text — there's no
        // signal to claim they're numeric.
        for i in 0..<columnCount where !hasAnyValue[i] {
            types[i] = .text
        }
        return types
    }
}

enum CSVPasteboard {
    static func copy(row: [String], separator: String) {
        write(row.joined(separator: separator))
    }

    static func copy(rows: [[String]], separator: String) {
        let joined = rows
            .map { $0.joined(separator: separator) }
            .joined(separator: "\n")
        write(joined)
    }

    private static func write(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
}
