import AppKit

@MainActor
final class CommandStripView: NSView {

    var onCommandSelected: ((String) -> Void)?
    var onCommandRemoved: ((String) -> Void)?

    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let moreButton = NSButton()
    private let hintLabel = NSTextField(labelWithString: "Type a /command to add shortcuts here")
    private let separator = NSBox()
    private var commands: [SlashCommand] = []
    private var popover: NSPopover?

    static let stripHeight: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Setup

    private func setupUI() {
        wantsLayer = true

        // Separator line at top
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Scroll view for pill buttons
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false
        addSubview(scrollView)

        // Stack view inside scroll view
        stackView.orientation = .horizontal
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = stackView

        // More button
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.bezelStyle = .recessed
        moreButton.isBordered = false
        moreButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "More commands")
        moreButton.imagePosition = .imageOnly
        moreButton.target = self
        moreButton.action = #selector(showMorePopover(_:))
        moreButton.toolTip = "All commands"
        addSubview(moreButton)

        // Hint label
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .center
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 22),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),

            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
        ])
    }

    // MARK: - Reload

    func reloadCommands(for directory: URL) {
        commands = SlashCommandStore.load(for: directory)
        rebuildButtons()
    }

    private func rebuildButtons() {
        // Close popover if showing to avoid stale data
        if let popover, popover.isShown { popover.close() }
        self.popover = nil

        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let hasCommands = !commands.isEmpty
        hintLabel.isHidden = hasCommands
        scrollView.isHidden = !hasCommands
        moreButton.isHidden = !hasCommands

        for command in commands {
            let button = makePillButton(title: command.command)
            stackView.addArrangedSubview(button)
        }
    }

    // MARK: - Pill Button

    private func makePillButton(title: String) -> NSButton {
        let button = PillButton(title: title)
        button.target = self
        button.action = #selector(pillButtonClicked(_:))

        let menu = NSMenu()
        let removeItem = NSMenuItem(title: "Remove", action: #selector(removeCommand(_:)), keyEquivalent: "")
        removeItem.target = self
        removeItem.representedObject = title
        menu.addItem(removeItem)
        button.menu = menu

        return button
    }

    @objc private func pillButtonClicked(_ sender: NSButton) {
        onCommandSelected?(sender.title)
    }

    @objc private func removeCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        onCommandRemoved?(command)
    }

    // MARK: - More Popover

    @objc private func showMorePopover(_ sender: NSButton) {
        if let existing = popover, existing.isShown {
            existing.close()
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient

        let listView = CommandListView(
            commands: commands,
            onSelect: { [weak self, weak popover] command in
                popover?.close()
                self?.onCommandSelected?(command)
            }
        )
        popover.contentViewController = CommandListHostingController(rootView: listView)
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        self.popover = popover
    }
}

// MARK: - PillButton

private final class PillButton: NSButton {
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = .recessed
        self.isBordered = false
        self.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        self.translatesAutoresizingMaskIntoConstraints = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 10
        updateBackground()

        let textWidth = (title as NSString).size(withAttributes: [.font: font!]).width
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: textWidth + 16),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func rightMouseDown(with event: NSEvent) {
        if let menu {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        let color: NSColor = isHovering
            ? NSColor.controlAccentColor.withAlphaComponent(0.2)
            : NSColor.controlColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = color.cgColor
        }
    }
}
