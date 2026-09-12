import SwiftUI

/// What Home's live dot does when it is tapped: it presents `LiveSessionPickerSheet` over Home rather than navigating, so `path` is taken and deliberately never written (BUG-054).
enum HomeLiveIndicator {
    static func open(pickerOpen: inout Bool, path: inout [AppRoute]) {
        pickerOpen = true
    }
}
