import Foundation
import Testing
@testable import QuarryKit

struct FilterTreeTests {
    let us = RowFilter(column: "country", value: "US")

    @Test func startsWithTheAllLineOnly() {
        let tree = FilterTree()
        #expect(tree.isEmpty)
        #expect(tree.rows.count == 1 && tree.rows[0].kind == .header(.all, isRoot: true))
        #expect(tree.whereClause == nil)
    }

    @Test func plusOnTheAllLineAddsTheFirstRule() {
        var tree = FilterTree()
        let id = tree.add(us, below: tree.root.id)
        #expect(tree.rows.map(\.depth) == [0, 1])
        #expect(tree.rule(id) == us)
        #expect(tree.whereClause == "`country` = 'US'")
    }

    @Test func rulesThatAreNotSetAreIgnored() {
        var tree = FilterTree(us)
        let empty = tree.add(RowFilter(column: "id"), below: tree.rules[0].id)
        #expect(tree.whereClause == "`country` = 'US'")
        tree.setRule(empty, RowFilter(column: "id", value: "4"))
        #expect(tree.whereClause == "`country` = 'US' AND `id` = '4'")
        #expect(FilterTree(RowFilter(column: "id")).whereClause == nil)
    }

    @Test func matchJoinsTheRules() {
        var tree = FilterTree(us)
        tree.add(RowFilter(column: "email", op: .isNull), below: tree.rules[0].id)
        tree.setMatch(tree.root.id, .any)
        #expect(tree.whereClause == "`country` = 'US' OR `email` IS NULL")
        tree.setMatch(tree.root.id, .none)
        #expect(tree.whereClause == "NOT (`country` = 'US' OR `email` IS NULL)")
    }

    @Test func plusInsertsOnTheLineBelow() {
        var tree = FilterTree(RowFilter(column: "a", value: "1"))
        let a = tree.rules[0].id
        let c = tree.add(RowFilter(column: "c"), below: a)
        let b = tree.add(RowFilter(column: "b"), below: a)
        let top = tree.add(RowFilter(column: "top"), below: tree.root.id)
        #expect(tree.rules.map(\.id) == [top, a, b, c])
    }

    @Test func groupGoesBelowTheRule() {
        var tree = FilterTree(us)
        let first = tree.rules[0].id
        let gb = tree.addGroup(RowFilter(column: "country", value: "GB"), below: first)
        let nl = tree.add(RowFilter(column: "country", value: "NL"), below: gb)
        #expect(tree.rows.map(\.depth) == [0, 1, 1, 2, 2])
        #expect(tree.rows[1].id == first)
        #expect(tree.rows[2].kind == .header(.any, isRoot: false))
        #expect(tree.rules.map(\.id) == [first, gb, nl])
        #expect(tree.whereClause == "`country` = 'US' AND (`country` = 'GB' OR `country` = 'NL')")
    }

    @Test func groupsAlternateAndNest() {
        var tree = FilterTree()
        tree.setMatch(tree.root.id, .any)
        let a = tree.addGroup(RowFilter(column: "a", value: "1"), below: tree.root.id)
        #expect(tree.rows[1].kind == .header(.all, isRoot: false))
        let b = tree.addGroup(RowFilter(column: "b", value: "2"), below: a)
        tree.add(RowFilter(column: "c", op: .between, value: "3", secondValue: "4"), below: b)
        #expect(tree.whereClause == "(`a` = '1' AND (`b` = '2' OR `c` BETWEEN '3' AND '4'))")
    }

    @Test func aGroupWithNothingSetIsIgnored() {
        var tree = FilterTree(us)
        tree.addGroup(RowFilter(column: "x"), below: tree.rules[0].id)
        #expect(tree.whereClause == "`country` = 'US'")
    }

    @Test func minusOnTheAllLineRemovesEveryRule() {
        var tree = FilterTree(us)
        tree.addGroup(RowFilter(column: "x", value: "1"), below: tree.rules[0].id)
        tree.setMatch(tree.root.id, .any)
        tree.remove(tree.root.id)
        #expect(tree.isEmpty && tree.rows.count == 1 && tree.root.match == .any)
    }

    @Test func removingAGroupsLastRuleRemovesTheGroup() {
        var tree = FilterTree(us)
        let inner = tree.addGroup(RowFilter(column: "x"), below: tree.rules[0].id)
        tree.remove(inner)
        #expect(tree.rows.count == 2)
    }

    @Test func dragMovesBelowTheTarget() {
        var tree = FilterTree(RowFilter(column: "a"))
        let a = tree.rules[0].id
        let b = tree.add(RowFilter(column: "b"), below: a)
        let c = tree.addGroup(RowFilter(column: "c"), below: b)
        let group = tree.rows[3].id
        // a into the group, after c.
        do { let moved = tree.move(a, below: c); #expect(moved) }
        #expect(tree.rules.map(\.id) == [b, c, a])
        #expect(tree.rows.map(\.depth) == [0, 1, 1, 2, 2])
        // b onto the group's header: first in the group.
        do { let moved = tree.move(b, below: group); #expect(moved) }
        #expect(tree.rules.map(\.id) == [b, c, a] && tree.rows.map(\.depth) == [0, 1, 2, 2, 2])
        // The group onto the top line: it stays first.
        do { let moved = tree.move(a, below: tree.root.id); #expect(moved) }
        #expect(tree.rows.map(\.depth) == [0, 1, 1, 2, 2] && tree.rules.first?.id == a)
    }

    @Test func aGroupCantMoveIntoItself() {
        var tree = FilterTree(RowFilter(column: "a"))
        let c = tree.addGroup(RowFilter(column: "c"), below: tree.rules[0].id)
        let group = tree.rows[2].id
        let before = tree
        do { let moved = tree.move(group, below: c); #expect(!moved) }
        do { let moved = tree.move(group, below: group); #expect(!moved) }
        do { let moved = tree.move(tree.root.id, below: c); #expect(!moved) }
        #expect(tree == before)
    }

    @Test func draggingAGroupsLastRuleOutRemovesTheGroup() {
        var tree = FilterTree(RowFilter(column: "a"))
        let a = tree.rules[0].id
        let c = tree.addGroup(RowFilter(column: "c"), below: a)
        do { let moved = tree.move(c, below: a); #expect(moved) }
        #expect(tree.rules.map(\.id) == [a, c] && tree.rows.count == 3)
    }
}

struct SavedFilterTests {
    @Test func roundTripKeepsEmptyRules() throws {
        var tree = FilterTree(RowFilter(column: "country", value: "US"))
        let group = tree.addGroup(RowFilter(column: "id"), below: tree.rules[0].id)
        tree.add(RowFilter(column: "name", op: .between, value: "a", secondValue: "m"), below: group)
        tree.setMatch(tree.root.id, .none)
        let loaded = try #require(FilterTree.decoded(tree.encoded()))
        #expect(loaded.rules.map(\.rule) == tree.rules.map(\.rule))
        #expect(loaded.rows.map(\.depth) == tree.rows.map(\.depth))
        #expect(loaded.root.match == .none)
        #expect(loaded.whereClause == tree.whereClause)
        #expect(Set(loaded.rows.map(\.id)).isDisjoint(with: Set(tree.rows.map(\.id))))
        #expect(loaded.firstUnsetRule == loaded.rules[1].id)
    }

    @Test func garbageIsNil() {
        #expect(FilterTree.decoded(Data("nope".utf8)) == nil)
    }

    // MARK: S-061 WHERE clause rules

    @Test func aTypedClauseIsWrappedSoItCantEscapeItsGroup() {
        var tree = FilterTree(RowFilter(column: "country", value: "US"))
        tree.add(RowFilter(column: "id", op: .sql, value: "  id < 3 OR id > 90 "), below: tree.rules[0].id)
        #expect(tree.whereClause == "`country` = 'US' AND (id < 3 OR id > 90\n)")
    }

    @Test func aTrailingCommentEndsAtTheLineBreak() {
        let rule = RowFilter(column: "id", op: .sql, value: "id = 1 -- just one")
        #expect(rule.whereClause == "(id = 1 -- just one\n)")
    }

    @Test func anEmptyTypedClauseIsIgnored() {
        #expect(RowFilter(column: "id", op: .sql, value: " \n ").whereClause == nil)
        #expect(!RowFilter(column: "id", op: .sql).isSet)
    }

    @Test func aTypedClauseNamesNoColumnsAndUsesNoIndex() {
        var tree = FilterTree(RowFilter(column: "country", value: "US"))
        tree.add(RowFilter(column: "gone", op: .sql, value: "1"), below: tree.rules[0].id)
        #expect(tree.columns == ["country"])
        #expect(tree.typedClauses == ["1"])
        #expect(!RowFilter(column: "id", op: .sql, value: "id = 1").canUseIndex(indexed: ["id"]))
        #expect(!RowFilter.Operator.comparisons.contains(.sql))
    }

    @Test func aSavedTypedClauseComesBack() throws {
        var tree = FilterTree(RowFilter(column: "country", value: "US"))
        tree.add(RowFilter(column: "id", op: .sql, value: "total > 100"), below: tree.rules[0].id)
        let back = try #require(FilterTree.decoded(tree.encoded()))
        #expect(back.whereClause == tree.whereClause)
    }
}
