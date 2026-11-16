import Foundation

/// 增量 RFC 4180 CSV 解析器：按字节状态机逐块喂入，引号字段/转义引号/CRLF 可跨块边界，
/// 只保留当前字段与当前行，内存与文件大小无关（10 万行级流式导入）。
/// UTF-8 多字节字符可安全跨块：定界符均为 ASCII，字段字节在行结束时整体解码。
public final class CSVStreamParser {
    private var field: [UInt8] = []
    private var row: [String] = []
    private var inQuotes = false
    private var fieldStarted = false
    private var quotePending = false
    private var skipLF = false
    private var emittedRows = 0
    /// 暂扣的单空字段行：可能是文件末尾空行（丢弃）也可能是中间空行（后续有数据则补发）。
    private var pendingBlank: [String]?

    public init() {}

    /// 喂入一块数据，返回本块内完成的行。
    public func feed(_ data: Data) -> [[String]] {
        var completed: [[String]] = []
        for byte in data {
            if quotePending {
                quotePending = false
                if byte == UInt8(ascii: "\"") {
                    field.append(byte)
                    continue
                }
                inQuotes = false
            }
            if inQuotes {
                if byte == UInt8(ascii: "\"") {
                    quotePending = true
                } else {
                    field.append(byte)
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\"") where !fieldStarted:
                inQuotes = true
                fieldStarted = true
                skipLF = false
            case UInt8(ascii: ","):
                skipLF = false
                endField()
            case UInt8(ascii: "\r"):
                skipLF = true
                endRow(into: &completed)
            case UInt8(ascii: "\n"):
                if skipLF {
                    skipLF = false
                } else {
                    endRow(into: &completed)
                }
            default:
                skipLF = false
                field.append(byte)
                fieldStarted = true
            }
        }
        return completed
    }

    /// 文件结束：收尾未闭合引号与最后一行；末尾单个空字段行不视为数据行（孤行空文件除外）。
    public func finish() -> [[String]] {
        var completed: [[String]] = []
        if quotePending {
            quotePending = false
            inQuotes = false
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty {
            endRow(into: &completed)
        }
        if let blank = pendingBlank {
            pendingBlank = nil
            if emittedRows == 0 {
                completed.append(blank)
                emittedRows += 1
            }
        }
        return completed
    }

    private func endField() {
        row.append(String(decoding: field, as: UTF8.self))
        field.removeAll(keepingCapacity: true)
        fieldStarted = false
    }

    private func endRow(into completed: inout [[String]]) {
        endField()
        let finished = row
        row.removeAll(keepingCapacity: true)
        if finished.count == 1, finished[0].isEmpty, emittedRows > 0 || pendingBlank != nil {
            if let previous = pendingBlank {
                completed.append(previous)
                emittedRows += 1
            }
            pendingBlank = finished
            return
        }
        if let previous = pendingBlank {
            pendingBlank = nil
            completed.append(previous)
            emittedRows += 1
        }
        completed.append(finished)
        emittedRows += 1
    }
}