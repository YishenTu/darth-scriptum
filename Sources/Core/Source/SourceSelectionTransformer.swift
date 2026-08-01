import Foundation

enum SourceSelectionTransformer {
    static func transform(_ selection: NSRange, by edit: SourceEdit) -> NSRange {
        let replacementLength = (edit.replacement as NSString).length
        let editStart = edit.range.location
        let editEnd = NSMaxRange(edit.range)
        let selectionEnd = NSMaxRange(selection)

        if edit.range.length == 0 {
            if selection.length == 0 {
                let location =
                    selection.location >= editStart
                    ? selection.location + replacementLength
                    : selection.location
                return NSRange(location: location, length: 0)
            }
            if editStart <= selection.location {
                return NSRange(
                    location: selection.location + replacementLength,
                    length: selection.length
                )
            }
            if editStart < selectionEnd {
                return NSRange(
                    location: selection.location,
                    length: selection.length + replacementLength
                )
            }
            return selection
        }

        let start = transformedBoundary(
            selection.location,
            editStart: editStart,
            editEnd: editEnd,
            replacementLength: replacementLength,
            prefersTrailingEdge: false
        )
        let end = transformedBoundary(
            selectionEnd,
            editStart: editStart,
            editEnd: editEnd,
            replacementLength: replacementLength,
            prefersTrailingEdge: true
        )
        return NSRange(location: start, length: max(0, end - start))
    }

    private static func transformedBoundary(
        _ location: Int,
        editStart: Int,
        editEnd: Int,
        replacementLength: Int,
        prefersTrailingEdge: Bool
    ) -> Int {
        if location < editStart { return location }
        if location > editEnd {
            return location + replacementLength - (editEnd - editStart)
        }
        if location == editEnd {
            return editStart + replacementLength
        }
        return prefersTrailingEdge
            ? editStart + replacementLength
            : editStart
    }
}
