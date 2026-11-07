import Foundation

/// Decodes CEA-608 closed captions (as carried in ATSC A/53 cc_data) into on-screen rows.
final class CEA608Decoder {
    struct Row: Equatable, Identifiable {
        var id: Int { row }
        /// 1...15, top to bottom.
        var row: Int
        var indent: Int
        var text: String
        var italic: Bool
    }

    /// 1 = CC1 (default), 2 = CC2, 3 = CC3, 4 = CC4.
    var channel = 1
    /// Called whenever the displayed caption changes.
    var onChange: (([Row]) -> Void)?

    private enum Mode { case popOn, rollUp(Int), paintOn, text }

    private struct Cell { var char: Character = " "; var italic = false }
    private typealias Screen = [[Cell]]

    private var mode: Mode = .popOn
    private var displayed = CEA608Decoder.blank()
    private var nonDisplayed = CEA608Decoder.blank()
    private var cursorRow = 15
    private var cursorCol = 0
    private var italic = false
    private var lastControl: (UInt8, UInt8)?
    private var activeChannel = 1 // channel the last control code addressed
    private var lastEmitted: [Row] = []

    private static func blank() -> Screen { Array(repeating: Array(repeating: Cell(), count: 32), count: 16) }

    func reset() {
        displayed = Self.blank(); nonDisplayed = Self.blank()
        mode = .popOn; cursorRow = 15; cursorCol = 0
        lastControl = nil
        emit()
    }

    /// Feeds cc_data triplets: (marker|cc_valid|cc_type, cc_data_1, cc_data_2)…
    func feed(_ triplets: [UInt8]) {
        var i = 0
        let wantField = channel <= 2 ? 0 : 1
        while i + 2 < triplets.count {
            let header = triplets[i], d1 = triplets[i + 1] & 0x7F, d2 = triplets[i + 2] & 0x7F
            i += 3
            let valid = header & 0x04 != 0
            let type = Int(header & 0x03)
            guard valid, type == wantField else { continue }
            process(d1, d2)
        }
    }

    private var writingScreenIsDisplayed: Bool {
        if case .popOn = mode { return false }
        return true
    }

    private func process(_ d1: UInt8, _ d2: UInt8) {
        if d1 == 0 && d2 == 0 { return }
        if d1 >= 0x10 && d1 <= 0x1F {
            // Control codes are sent twice; act on the first only.
            if let last = lastControl, last == (d1, d2) { lastControl = nil; return }
            lastControl = (d1, d2)
            let ch = (d1 & 0x08) != 0 ? 2 : 1
            activeChannel = channel <= 2 ? ch : ch + 2
            guard activeChannel == channel else { return }
            handleControl(d1 & 0xF7, d2)
            return
        }
        lastControl = nil
        guard activeChannel == channel else { return }
        if d1 >= 0x20 { put(Self.char(d1)) }
        if d2 >= 0x20 { put(Self.char(d2)) }
        if case .popOn = mode {} else { emit() }
    }

    private func handleControl(_ d1: UInt8, _ d2: UInt8) {
        // Preamble address codes.
        if d2 >= 0x40 && d2 <= 0x7F {
            let row = Self.pacRow(d1, d2)
            guard row > 0 else { return }
            if case let .rollUp(n) = mode, row != cursorRow {
                // Move the roll-up window to the new base row.
                var screen = displayed
                let shift = row - cursorRow
                var moved = Self.blank()
                for r in 1...15 where r + shift >= 1 && r + shift <= 15 && r > cursorRow - n {
                    moved[r + shift] = screen[r]
                }
                screen = moved
                displayed = screen
            }
            cursorRow = row
            let attrs = d2 & 0x1F
            if attrs & 0x10 != 0 {
                cursorCol = Int((attrs & 0x0E) >> 1) * 4
                italic = false
            } else {
                cursorCol = 0
                italic = (attrs & 0x0E) == 0x0E
            }
            return
        }
        switch (d1, d2) {
        case (0x11, 0x20...0x2F): // mid-row style
            italic = (d2 & 0x0E) == 0x0E
            put(" ")
        case (0x11, 0x30...0x3F):
            put(Self.special[Int(d2 - 0x30)])
        case (0x12, 0x20...0x3F), (0x13, 0x20...0x3F):
            backspace()
            let table = d1 == 0x12 ? Self.extendedSpanishFrench : Self.extendedPortugueseGerman
            put(table[Int(d2 - 0x20)])
        case (0x14, _), (0x15, _):
            handleMisc(d2)
        case (0x17, 0x21...0x23):
            cursorCol = min(cursorCol + Int(d2 - 0x20), 31)
        default:
            break
        }
        if case .popOn = mode {} else { emit() }
    }

    private func handleMisc(_ d2: UInt8) {
        switch d2 {
        case 0x20: mode = .popOn
        case 0x21: backspace()
        case 0x24: // delete to end of row
            for c in cursorCol..<32 { setCell(cursorRow, c, Cell()) }
        case 0x25, 0x26, 0x27:
            let rows = Int(d2 - 0x23)
            if case .rollUp = mode {} else {
                displayed = Self.blank(); nonDisplayed = Self.blank()
                cursorRow = 15
            }
            mode = .rollUp(rows)
            cursorCol = 0
        case 0x29: mode = .paintOn
        case 0x2A, 0x2B: mode = .text
        case 0x2C:
            displayed = Self.blank()
            emit()
        case 0x2D: carriageReturn()
        case 0x2E: nonDisplayed = Self.blank()
        case 0x2F:
            swap(&displayed, &nonDisplayed)
            emit()
        default: break
        }
    }

    private func carriageReturn() {
        guard case let .rollUp(n) = mode else { cursorCol = 0; return }
        var screen = displayed
        let top = max(cursorRow - n + 1, 1)
        for r in top..<cursorRow { screen[r] = screen[r + 1] }
        if top > 1 { for r in 1..<top { screen[r] = Array(repeating: Cell(), count: 32) } }
        screen[cursorRow] = Array(repeating: Cell(), count: 32)
        displayed = screen
        cursorCol = 0
        emit()
    }

    private func backspace() {
        guard cursorCol > 0 else { return }
        cursorCol -= 1
        setCell(cursorRow, cursorCol, Cell())
    }

    private func put(_ ch: Character) {
        guard cursorRow >= 1 && cursorRow <= 15 else { return }
        setCell(cursorRow, min(cursorCol, 31), Cell(char: ch, italic: italic))
        if cursorCol < 31 { cursorCol += 1 }
    }

    private func setCell(_ row: Int, _ col: Int, _ cell: Cell) {
        guard row >= 1 && row <= 15 && col >= 0 && col < 32 else { return }
        if writingScreenIsDisplayed { displayed[row][col] = cell } else { nonDisplayed[row][col] = cell }
    }

    private func emit() {
        var rows: [Row] = []
        for r in 1...15 {
            let cells = displayed[r]
            let text = String(cells.map(\.char))
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let indent = text.prefix { $0 == " " }.count
            rows.append(Row(row: r, indent: indent, text: trimmed, italic: cells.contains { $0.italic && $0.char != " " }))
        }
        guard rows != lastEmitted else { return }
        lastEmitted = rows
        onChange?(rows)
    }

    // MARK: Tables

    private static func pacRow(_ d1: UInt8, _ d2: UInt8) -> Int {
        let high = d2 >= 0x60
        switch d1 {
        case 0x11: return high ? 2 : 1
        case 0x12: return high ? 4 : 3
        case 0x15: return high ? 6 : 5
        case 0x16: return high ? 8 : 7
        case 0x17: return high ? 10 : 9
        case 0x10: return high ? 0 : 11
        case 0x13: return high ? 13 : 12
        case 0x14: return high ? 15 : 14
        default: return 0
        }
    }

    private static func char(_ c: UInt8) -> Character {
        switch c {
        case 0x2A: return "á"
        case 0x5C: return "é"
        case 0x5E: return "í"
        case 0x5F: return "ó"
        case 0x60: return "ú"
        case 0x7B: return "ç"
        case 0x7C: return "÷"
        case 0x7D: return "Ñ"
        case 0x7E: return "ñ"
        case 0x7F: return "█"
        default: return Character(UnicodeScalar(c))
        }
    }

    private static let special: [Character] = ["®", "°", "½", "¿", "™", "¢", "£", "♪", "à", " ", "è", "â", "ê", "î", "ô", "û"]

    private static let extendedSpanishFrench: [Character] = [
        "Á", "É", "Ó", "Ú", "Ü", "ü", "‘", "¡", "*", "'", "—", "©", "℠", "•", "“", "”",
        "À", "Â", "Ç", "È", "Ê", "Ë", "ë", "Î", "Ï", "ï", "Ô", "Ù", "ù", "Û", "«", "»",
    ]

    private static let extendedPortugueseGerman: [Character] = [
        "Ã", "ã", "Í", "Ì", "ì", "Ò", "ò", "Õ", "õ", "{", "}", "\\", "^", "_", "|", "~",
        "Ä", "ä", "Ö", "ö", "ß", "¥", "¤", "│", "Å", "å", "Ø", "ø", "┌", "┐", "└", "┘",
    ]
}
