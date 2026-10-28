//
//  URLHighlightTests.swift
//

import Foundation
import Testing

@testable import SwiftTerm

final class URLHighlightTests: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {
    }

    @Test func findsURLsButNotPaths() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 3))
        terminal.feed(text: "see https://example.com/a and /usr/local/bin\r\n")
        terminal.feed(text: "mail mailto:me@example.com\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<3)
        #expect(ranges[0] == [4..<25])
        #expect(ranges[1] == [5..<26])
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

    @Test func findsPathsWhenAsked() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 2))
        terminal.feed(text: "see https://example.com/a and /usr/local/bin\r\n")

        let both = terminal.implicitURLRanges(rows: 0..<2, urls: true, paths: true)
        #expect(both[0] == [4..<25, 30..<44])
        let pathsOnly = terminal.implicitURLRanges(rows: 0..<2, urls: false, paths: true)
        #expect(pathsOnly[0] == [30..<44])
    }

    @Test func pathsEndAtASpace() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 60, rows: 2))
        terminal.feed(text: "abs /usr/local/bin and /etc/hosts\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<1, urls: false, paths: true)
        #expect(ranges[0] == [4..<18, 23..<33])
        #expect(terminal.implicitLink(at: Position(col: 25, row: 0), urls: false, paths: true) == "/etc/hosts")
    }

    @Test func listingColumnsDoNotJoinIntoAPath() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 30, rows: 3))
        terminal.feed(text: "build/        RexRemote.xcodeproj/\r\nMakefile      Tests/\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<3, urls: false, paths: true)
        #expect(ranges[1]?.contains(0..<8) != true)
    }

    @Test func joinsAPathThatFillsTheRowWithoutAWrapMark() {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 10, rows: 3))
        // Two hard lines, as a restored screen gives them.
        terminal.feed(text: "see ./Make\r\nfile ok\r\n")

        let ranges = terminal.implicitURLRanges(rows: 0..<2, urls: false, paths: true)
        #expect(ranges[0] == [4..<10])
        #expect(ranges[1] == [0..<4])
    }

    @Test func recognizesURLSchemes() {
        #expect(Terminal.isImplicitURL("HTTPS://example.com"))
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

        view.highlightsPaths = true
        #expect(view.linkForClick(at: Position(col: 32, row: 0), hasCommandModifier: false)?.link == "/tmp/file")
    }
#endif
}
