import Foundation
import QuarryKit

/// Info's changes (S-027), run by `InfoController`. Other views reload after,
/// since an engine change can drop foreign keys and the create statement changes.
extension Session {
    func requestTableEngine(_ engine: String) { info.requestEngine(engine) }

    func confirmTableEngine() { afterInfoChange(info.confirmEngine()) }

    func setTableCharset(_ charset: String) { afterInfoChange(info.setCharset(charset)) }

    func setTableCollation(_ collation: String) { afterInfoChange(info.setCollation(collation)) }

    func commitTableComment() { afterInfoChange(info.commitComment()) }

    func commitAutoIncrement() { afterInfoChange(info.commitAutoIncrement()) }

    func resetAutoIncrement() {
        view = .info
        afterInfoChange(info.resetAutoIncrement())
    }

    /// The self-test awaits `currentLoad`.
    private func afterInfoChange(_ task: Task<Void, Never>?) {
        guard let task else { return }
        currentLoad = Task {
            await task.value
            structure.invalidate()
            content.invalidate()
            foreignKeys.invalidate()
        }
    }
}
