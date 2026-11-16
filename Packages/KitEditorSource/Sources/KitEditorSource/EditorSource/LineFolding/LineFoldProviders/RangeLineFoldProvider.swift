//
//  RangeLineFoldProvider.swift
//  EditorSource
//
//  A generic, syntax-agnostic fold provider driven by precomputed fold ranges.
//

import AppKit
import EditorTextView

/// A fold provider that derives fold regions from a set of document ranges supplied by a closure.
///
/// Unlike indentation folding, this works for languages whose foldable blocks are delimited by
/// syntax (parentheses, `BEGIN…END`, statements) rather than whitespace. The host plugin computes
/// the ranges (e.g. from a SQL parser); this provider converts them into the per-line depth
/// transitions the fold calculator consumes.
///
/// Ranges are UTF-16 `NSRange`s covering a whole block (including its delimiters). Only ranges that
/// span multiple lines produce a fold: the opening line stays visible, the interior lines collapse,
/// and the closing line stays visible.
@MainActor
public final class RangeLineFoldProvider: LineFoldProvider {
    private let rangesProvider: (String) -> [NSRange]

    /// Cache rebuilt at the start of each fold pass (line 0) or when the document length changes.
    private var cachedLength: Int = -1
    private var lineStarts: [Int] = []
    private var lineDepths: [Int] = []

    /// - Parameter rangesProvider: Returns the foldable block ranges for the current document text.
    public init(rangesProvider: @escaping (String) -> [NSRange]) {
        self.rangesProvider = rangesProvider
    }

    public func foldLevelAtLine(
        lineNumber: Int,
        lineRange: NSRange,
        previousDepth: Int,
        controller: TextViewController
    ) -> [LineFoldProviderLineInfo] {
        let text = controller.textView.textStorage.string as NSString
        rebuildCacheIfNeeded(text: text, lineNumber: lineNumber)

        let leadingDepth = depth(atLine: lineNumber)
        var indicators: [LineFoldProviderLineInfo] = []

        if leadingDepth < previousDepth {
            let lineStart = lineNumber < lineStarts.count ? lineStarts[lineNumber] : lineRange.location
            indicators.append(.endFold(rangeEnd: lineStart, newDepth: leadingDepth))
        }

        let nextDepth = depth(atLine: lineNumber + 1)
        if nextDepth > leadingDepth {
            indicators.append(.startFold(rangeStart: contentEnd(ofLine: lineNumber, in: text), newDepth: nextDepth))
        }

        return indicators
    }

    // MARK: - Cache

    private func depth(atLine line: Int) -> Int {
        guard line >= 0, line < lineDepths.count else { return 0 }
        return lineDepths[line]
    }

    private func rebuildCacheIfNeeded(text: NSString, lineNumber: Int) {
        guard lineNumber == 0 || text.length != cachedLength else { return }
        cachedLength = text.length

        // Line start offsets (UTF-16). Line 0 starts at 0; each '\n' begins the next line.
        var starts: [Int] = [0]
        var idx = 0
        while idx < text.length {
            if text.character(at: idx) == 10 { // '\n'
                starts.append(idx + 1)
            }
            idx += 1
        }
        lineStarts = starts

        // Nesting depth per line via a difference array: a block contributes +1 to the lines
        // strictly between its opening line and its closing line.
        var diff = [Int](repeating: 0, count: starts.count + 1)
        for range in rangesProvider(text as String) {
            guard range.length > 0, range.location >= 0, range.upperBound <= text.length else { continue }
            let openingLine = lineIndex(containing: range.location, starts: starts)
            let closingLine = lineIndex(containing: max(range.location, range.upperBound - 1), starts: starts)
            guard openingLine < closingLine else { continue } // single-line block: nothing to fold
            diff[openingLine + 1] += 1
            diff[closingLine] -= 1
        }

        var depths: [Int] = []
        depths.reserveCapacity(starts.count)
        var running = 0
        for i in 0..<starts.count {
            running += diff[i]
            depths.append(running)
        }
        lineDepths = depths
    }

    /// Binary search for the line whose start offset is the greatest ≤ `offset`.
    private func lineIndex(containing offset: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// UTF-16 offset where the line's visible content ends (before trailing whitespace/newline).
    private func contentEnd(ofLine line: Int, in text: NSString) -> Int {
        guard line < lineStarts.count else { return text.length }
        let start = lineStarts[line]
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : text.length
        var cursor = end
        while cursor > start {
            let scalar = UnicodeScalar(text.character(at: cursor - 1))
            if scalar?.properties.isWhitespace == true {
                cursor -= 1
            } else {
                break
            }
        }
        return cursor
    }
}