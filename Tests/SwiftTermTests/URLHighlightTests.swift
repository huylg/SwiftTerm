//
//  URLHighlightTests.swift
//

import Foundation
import Testing

@testable import SwiftTerm

final class URLHighlightTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    @Test func findsWebURLsOnly() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 3))
        terminal.feed(text: "see https://example.com/a and /usr/local/bin\r\n")
        terminal.feed(text: "mail mailto:me@example.com\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<3)
        #expect(ranges[0] == [4..<25])
        #expect(ranges[1] == nil)
        #expect(ranges[2] == nil)
    }

    @Test func followsAWrappedURLAcrossRows() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 3))
        terminal.feed(text: "https://example.com/x")

        let ranges = terminal.implicitURLRanges(rows: 0..<3)
        #expect(ranges[0] == [0..<10])
        #expect(ranges[1] == [0..<10])
        #expect(ranges[2] == [0..<1])

        // Only the lower rows are visible: the URL still starts above them.
        let lower = terminal.implicitURLRanges(rows: 1..<3)
        #expect(lower[0] == nil)
        #expect(lower[1] == [0..<10])
    }

    @Test func aListItemAfterAURLStaysApart() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 45, rows: 3))
        terminal.feed(text: "  https://github.com/huylg/SwiftTerm/pull/6\r\n- rex-ios:\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<3)
        #expect(ranges[0] == [2..<43])
        #expect(ranges[1] == nil)
        #expect(terminal.implicitURL(at: Position(col: 10, row: 0)) == "https://github.com/huylg/SwiftTerm/pull/6")
    }

    @Test func aListItemAfterAURLAtTheEdgeStaysApart() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 43, rows: 3))
        terminal.feed(text: "  https://github.com/huylg/SwiftTerm/pull/6\r\n- rex-ios:\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<3)
        #expect(ranges[0] == [2..<43])
        #expect(ranges[1] == nil)
    }

    @Test func joinsAURLAProgramWrappedAtTheEdge() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 20, rows: 3))
        // Hard line ends, as a program that wraps text itself writes them.
        terminal.feed(text: "  https://example.co\r\n  m/a/b done\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<3)
        #expect(ranges[0] == [2..<20])
        #expect(ranges[1] == [2..<7])
        #expect(terminal.implicitURL(at: Position(col: 3, row: 1)) == "https://example.com/a/b")
    }

    @Test func recognizesURLSchemes() {
        #expect(Terminal.isImplicitURL("HTTPS://example.com"))
        #expect(!Terminal.isImplicitURL("mailto:me@example.com"))
        #expect(!Terminal.isImplicitURL("/usr/local/bin"))
        #expect(!Terminal.isImplicitURL("src/main.swift:12"))
    }

#if os(macOS)
    @MainActor
    @Test func clickOpensAURLOnlyWhenHighlighted() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        view.feed(text: "go https://example.com/x now /tmp/file")

        #expect(view.linkForClick(at: Position(col: 5, row: 0), hasCommandModifier: false) == nil)

        view.highlightsURLs = true
        #expect(view.linkForClick(at: Position(col: 5, row: 0), hasCommandModifier: false)?.link == "https://example.com/x")
        #expect(view.linkForClick(at: Position(col: 32, row: 0), hasCommandModifier: false) == nil)
        #expect(view.linkForClick(at: Position(col: 0, row: 0), hasCommandModifier: false) == nil)
    }
#endif
}
