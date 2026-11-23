import Foundation
import QuarryControllers
import QuarryKit

/// The Field Editor (S-012) uses AppKit, so Content builds it on the app's side
/// of the QuarryControllers seam.
extension ContentController {
    /// The Field Editor for one cell; `typed` carries an inline edit over.
    /// Saving runs the same UPDATE as an inline edit; a new row is then saved.
    func fieldEditor(row: Int, column: Int, typed: String? = nil,
                     save: @escaping (Int, Int, CellValue) -> Void) -> FieldEditor? {
        guard row < grid.rows.count, column < grid.rows[row].count, column < columns.count else { return nil }
        let editable = canChange(row: row, column: column) && !isLoading
        return FieldEditor(fieldName: columns[column].name, fieldType: fieldType(column: column), row: row,
                           column: column, value: grid.rows[row][column], typed: typed, isEditable: editable) { _, value in
            save(row, column, value)
        }
    }
}
