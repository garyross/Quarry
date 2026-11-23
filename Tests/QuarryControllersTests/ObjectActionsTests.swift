import Foundation
import Testing
import QuarryKit
import QuarryControllers

/// Which sidebar commands apply (S-021, S-022, S-030; FIXLOG read-only Delete).
@Suite struct ObjectActionsTests {
    static let orders = DBObject(name: "orders", kind: .table)
    static let items = DBObject(name: "order_items", kind: .table)
    static let totals = DBObject(name: "order_totals", kind: .view)
    static let refresh = DBObject(name: "refresh_totals", kind: .procedure)
    static let tax = DBObject(name: "tax", kind: .function)
    static let all = [orders, items, totals, refresh, tax]

    static func actions(_ clicked: [DBObject]? = nil, selection: [DBObject] = [], shown: DBObject? = nil,
                        isConnected: Bool = true, database: String? = "quarry_demo", isReadOnly: Bool = false,
                        engine: Engine = .mysql) -> ObjectActions {
        ObjectActions(isConnected: isConnected, database: database, isReadOnly: isReadOnly, engine: engine, objects: all,
                      clicked: clicked.map { Set($0.map(\.id)) }, selection: Set(selection.map(\.id)), shown: shown?.id)
    }

    /// Every command that writes, for one set of rows.
    static func anyWrite(_ actions: ObjectActions) -> Bool {
        actions.rename != nil || actions.duplicate != nil || !actions.empty.isEmpty || !actions.delete.isEmpty
            || actions.definition != nil || ObjectKind.allCases.contains(where: actions.canCreate)
    }

    @Test func aReadOnlyFileOffersNoWriteCommandForAnyObject() {
        for object in Self.all {
            for clicked in [[object], nil] {
                let actions = Self.actions(clicked, selection: [object], shown: object, isReadOnly: true, engine: .sqlite)
                #expect(!Self.anyWrite(actions), "\(object.name)")
                // Reading commands still see the targets (Check, Show Create Statement).
                #expect(actions.targets == [object])
            }
        }
        #expect(!Self.anyWrite(Self.actions(Self.all, isReadOnly: true, engine: .sqlite)))
    }

    @Test func nothingAppliesWithoutAConnectionOrADatabase() {
        for actions in [Self.actions([Self.orders], isConnected: false), Self.actions([Self.orders], database: nil)] {
            #expect(actions.targets.isEmpty)
            #expect(!Self.anyWrite(actions))
        }
    }

    @Test func clickedRowsWinOverTheSelectionWhichWinsOverTheShownObject() {
        #expect(Self.actions([Self.items], selection: [Self.orders], shown: Self.totals).targets == [Self.items])
        #expect(Self.actions(selection: [Self.orders], shown: Self.totals).targets == [Self.orders])
        #expect(Self.actions(shown: Self.totals).targets == [Self.totals])
        // In sidebar order, whatever the click order.
        #expect(Self.actions([Self.tax, Self.orders]).targets == [Self.orders, Self.tax])
    }

    @Test func renameTakesOneTableOrViewAndDuplicateOneTable() {
        #expect(Self.actions([Self.orders]).rename == Self.orders)
        #expect(Self.actions([Self.totals]).rename == Self.totals)
        #expect(Self.actions([Self.refresh]).rename == nil)
        #expect(Self.actions([Self.orders, Self.items]).rename == nil)
        #expect(Self.actions([Self.orders]).duplicate == Self.orders)
        #expect(Self.actions([Self.totals]).duplicate == nil)
    }

    @Test func emptyNeedsEveryTargetToBeATableAndDeleteTakesAnything() {
        #expect(Self.actions([Self.orders, Self.items]).empty == [Self.orders, Self.items])
        #expect(Self.actions([Self.orders, Self.totals]).empty.isEmpty)
        #expect(Self.actions(Self.all).delete == Self.all)
    }

    @Test func editTakesOneClickedOrSelectedViewOrRoutineButNotTheShownObject() {
        #expect(Self.actions([Self.refresh]).definition == Self.refresh)
        #expect(Self.actions(selection: [Self.totals]).definition == Self.totals)
        #expect(Self.actions(shown: Self.totals).definition == nil)
        #expect(Self.actions([Self.orders]).definition == nil)
        #expect(Self.actions([Self.totals, Self.tax]).definition == nil)
    }

    @Test func aSQLiteFileCreatesTablesAndViewsButNoRoutines() {
        let sqlite = Self.actions(engine: .sqlite)
        #expect(sqlite.canCreate(.table) && sqlite.canCreate(.view))
        #expect(!sqlite.canCreate(.procedure) && !sqlite.canCreate(.function))
        #expect(ObjectKind.allCases.allSatisfy(Self.actions().canCreate))
    }

    @Test func titlesNameWhatTheCommandWorksOn() {
        #expect(Self.actions([Self.orders]).renameTitle == "Rename Table…")
        #expect(Self.actions([Self.totals]).deleteTitle == "Delete View…")
        #expect(Self.actions([Self.refresh]).deleteTitle == "Delete Procedure…")
        #expect(Self.actions([Self.orders, Self.totals, Self.tax]).deleteTitle == "Delete 3 Items…")
        #expect(Self.actions([Self.orders, Self.items]).emptyTitle == "Empty 2 Tables…")
        #expect(Self.actions([Self.tax]).editDefinitionTitle == "Edit Function…")
        #expect(Self.actions().editDefinitionTitle == "Edit View…")
    }
}
