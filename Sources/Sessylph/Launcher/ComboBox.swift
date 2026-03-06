import SwiftUI

/// A SwiftUI wrapper around NSComboBox — editable text field with a dropdown of suggestions.
struct ComboBox: NSViewRepresentable {
    var items: [String]
    @Binding var text: String
    var placeholder: String = ""

    func makeNSView(context: Context) -> NSComboBox {
        let comboBox = NSComboBox()
        comboBox.usesDataSource = false
        comboBox.completes = true
        comboBox.isEditable = true
        comboBox.hasVerticalScroller = true
        comboBox.numberOfVisibleItems = 8
        comboBox.placeholderString = placeholder
        comboBox.delegate = context.coordinator
        comboBox.target = context.coordinator
        comboBox.action = #selector(Coordinator.comboBoxSelectionChanged(_:))
        return comboBox
    }

    func updateNSView(_ comboBox: NSComboBox, context: Context) {
        comboBox.removeAllItems()
        comboBox.addItems(withObjectValues: items)
        if comboBox.stringValue != text {
            comboBox.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSComboBoxDelegate {
        var parent: ComboBox

        init(_ parent: ComboBox) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let comboBox = obj.object as? NSComboBox else { return }
            parent.text = comboBox.stringValue
        }

        @objc func comboBoxSelectionChanged(_ sender: NSComboBox) {
            parent.text = sender.stringValue
        }

        func comboBoxSelectionDidChange(_ notification: Notification) {
            guard let comboBox = notification.object as? NSComboBox,
                  comboBox.indexOfSelectedItem >= 0
            else { return }
            parent.text = comboBox.itemObjectValue(at: comboBox.indexOfSelectedItem) as? String ?? ""
        }
    }
}
