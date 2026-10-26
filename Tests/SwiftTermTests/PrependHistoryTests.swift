//
//  PrependHistoryTests.swift
//
//  `Terminal.prependHistory(from:)` adds old scrollback above the oldest row, as a
//  restored snapshot's history arrives newest page first.
//

import Foundation
import Testing

@testable import SwiftTerm

@Suite struct PrependHistoryTests {

    final class Delegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func terminal(rows: Int, scrollback: Int = 100) -> Terminal {
        Terminal(delegate: Delegate(), options: TerminalOptions(cols: 10, rows: rows, scrollback: scrollback))
    }

    private func text(_ terminal: Terminal) -> [String] {
        let buffer = terminal.normalBuffer
        return (0..<buffer.lines.count).map { buffer.lines[$0].translateToString(trimRight: true) }
    }

    @Test func pagesLandAboveTheOldestRowInOrder() {
        let live = terminal(rows: 3)
        live.feed(text: "a\r\nb\r\nc\r\nd")
        let yBase = live.normalBuffer.yBase
        let yDisp = live.normalBuffer.yDisp

        let newer = terminal(rows: 2)
        newer.feed(text: "p3\r\np4")
        #expect(live.prependHistory(from: newer) == 2)
        let older = terminal(rows: 2)
        older.feed(text: "p1\r\np2")
        #expect(live.prependHistory(from: older) == 2)

        #expect(text(live) == ["p1", "p2", "p3", "p4", "a", "b", "c", "d"])
        #expect(live.normalBuffer.yBase == yBase + 4)
        #expect(live.normalBuffer.yDisp == yDisp + 4)
    }

    @Test func rowsBelowTheSourceCursorAreLeftOut() {
        let live = terminal(rows: 3)
        live.feed(text: "a")
        let page = terminal(rows: 5)
        page.feed(text: "x\r\ny")
        #expect(live.prependHistory(from: page) == 2)
        #expect(Array(text(live).prefix(3)) == ["x", "y", "a"])
    }

    @Test func aFullScrollbackKeepsTheNewestRowsThatFit() {
        let live = terminal(rows: 2, scrollback: 3)
        live.feed(text: "a\r\nb")
        let page = terminal(rows: 5)
        page.feed(text: "1\r\n2\r\n3\r\n4\r\n5")
        // Two screen rows plus three of scrollback: room for three more.
        #expect(live.prependHistory(from: page) == 3)
        #expect(text(live) == ["3", "4", "5", "a", "b"])
        #expect(live.prependHistory(from: page) == 0)
    }

    @Test func outputAfterAPrependScrollsNormally() {
        let live = terminal(rows: 2)
        live.feed(text: "a\r\nb")
        let page = terminal(rows: 2)
        page.feed(text: "old")
        live.prependHistory(from: page)
        live.feed(text: "\r\nc\r\nd")
        #expect(text(live) == ["old", "a", "b", "c", "d"])
        #expect(live.normalBuffer.lines[0].owningBuffer === live.normalBuffer)
    }

    @Test func wrappedRowsKeepTheirWrapFlag() {
        let live = terminal(rows: 2)
        live.feed(text: "a")
        let page = terminal(rows: 3)
        page.feed(text: "0123456789ab")
        #expect(live.prependHistory(from: page) == 2)
        #expect(live.normalBuffer.lines[0].isWrapped == false)
        #expect(live.normalBuffer.lines[1].isWrapped == true)
    }
}
