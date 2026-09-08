import RunestoneEditor
import UIKit

extension TextViewerViewController {
    // MARK: - Find

    func toggleFind() {
        findBar.isHidden.toggle()
        if findBar.isHidden {
            findBar.endEditing(true)
        } else {
            findBar.becomeFirstResponderOnField()
        }
    }

    func find(_ term: String, forwards: Bool) {
        guard !term.isEmpty else { return findBar.showResult(nil) }
        let text = textView.text as NSString
        let selection = textView.selectedRange
        var first: NSRange?
        var last: NSRange?
        var target: NSRange?
        var count = 0
        var current = 0
        var position = 0
        while position < text.length {
            let match = text.range(
                of: term,
                options: [.caseInsensitive],
                range: NSRange(location: position, length: text.length - position)
            )
            guard match.location != NSNotFound, match.length > 0 else { break }
            count += 1
            if first == nil {
                first = match
            }
            last = match
            let conditionA = target == nil && match.location >= NSMaxRange(selection)
            let conditionB = forwards ? conditionA : NSMaxRange(match) <= selection.location
            if conditionB {
                target = match
                current = count
            }
            position = NSMaxRange(match)
        }
        guard let first, let last else {
            findBar.showResult(String(localized: "No results"))
            return
        }
        if target == nil {
            target = forwards ? first : last
            current = forwards ? 1 : count
        }
        guard let target else { return }
        textView.selectedRange = target
        textView.scrollRangeToVisible(target)
        findBar.showResult(String(format: String(localized: "%lld of %lld"), Int64(current), Int64(count)))
    }
}
