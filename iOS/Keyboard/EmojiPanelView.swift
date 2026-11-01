import UIKit

/// The emoji panel (ARCHITECTURE.md, "Emoji panel"): on the emoji layer it covers the key area above the bottom row
/// with a horizontally scrolling grid, recents first and then the catalog's categories, the shown category's name
/// above it, and a jump bar between the bottom row's keys (the layer key back to letters, and delete, which the key
/// area draws and handles). A tap on an emoji types it (`onEmoji`) and adds it to the recents, kept in the keyboard's
/// own `UserDefaults` (no Full Access needed); the grid keeps its order until the panel is shown again. It takes only
/// touches in the grid and the jump bar.
final class EmojiPanelView: UIView, UICollectionViewDataSource, UICollectionViewDelegate {
    /// An emoji was touched down: the press binds to the field served now, and the key area may drop or commit it.
    var onEmojiPressBegan: ((String) -> Void)?
    /// The press became a scroll, or ended without a selection: it types nothing.
    var onEmojiPressCancelled: (() -> Void)?
    var onEmoji: ((String) -> Void)?
    /// Bold Text: the category name and the jump bar's symbols are bold.
    var bold = false {
        didSet { if bold != oldValue { styleChrome() } }
    }

    private struct Section {
        var name: String
        var symbol: String
        var emoji: [String]
    }

    private static let recentsKey = "lf.emojiRecents"
    private static let shownTint = BrandPalette.dynamic(\.aurora)
    /// The catalog, split once.
    private static let catalog: [Section] = EmojiCatalog.categories.map { Section(name: $0.name, symbol: $0.symbol, emoji: $0.emoji) }

    private var recents = EmojiRecents(stored: UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
    private var sections: [Section] = []
    private var shownSection = 0
    private let flow = UICollectionViewFlowLayout()
    private lazy var grid = UICollectionView(frame: .zero, collectionViewLayout: flow)
    private let jumpBar = UIStackView()
    private var gridArea = CGRect.zero
    private var jumpArea = CGRect.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        flow.scrollDirection = .horizontal
        flow.minimumLineSpacing = 0
        flow.minimumInteritemSpacing = 0
        grid.backgroundColor = .clear
        grid.showsHorizontalScrollIndicator = false
        grid.dataSource = self
        grid.delegate = self
        grid.delaysContentTouches = false
        grid.register(EmojiCell.self, forCellWithReuseIdentifier: EmojiCell.reuseID)
        grid.accessibilityIdentifier = "lf.emoji.grid"
        addSubview(grid)
        jumpBar.axis = .horizontal
        jumpBar.distribution = .fillEqually
        jumpBar.accessibilityIdentifier = "lf.emoji.jumpBar"
        addSubview(jumpBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Places the grid and the jump bar, in the panel's coordinates. No category name: the gap between sections and
    /// the jump bar's highlighted symbol mark them, and the emoji get the height.
    func layout(grid gridFrame: CGRect, jumpBar jumpFrame: CGRect) {
        gridArea = gridFrame
        jumpArea = jumpFrame
        let gridRect = CGRect(x: gridFrame.minX, y: gridFrame.minY, width: gridFrame.width, height: max(gridFrame.height, 1))
        // Square cells about 40 points tall: four rows in portrait, three in landscape.
        let rows = max(2, Int(gridRect.height / 34))
        let side = floor(gridRect.height / CGFloat(rows))
        if flow.itemSize.width != side {
            flow.itemSize = CGSize(width: side, height: side)
            flow.sectionInset = UIEdgeInsets(top: 0, left: 6, bottom: gridRect.height - side * CGFloat(rows), right: 6)
            flow.invalidateLayout()
        }
        grid.frame = gridRect
        jumpBar.frame = jumpFrame.insetBy(dx: 0, dy: (jumpFrame.height - min(jumpFrame.height, 40)) / 2)
    }

    /// The panel is shown: recents first (when there are any), from the start.
    func reload() {
        sections = (recents.emoji.isEmpty ? [] : [Section(name: "Frequently Used", symbol: "clock", emoji: recents.emoji)])
            + Self.catalog
        grid.reloadData()
        grid.layoutIfNeeded()
        grid.setContentOffset(.zero, animated: false)
        rebuildJumpBar()
        show(section: 0)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        gridArea.contains(point) || jumpArea.contains(point)
    }

    // A touch on the panel between its controls (the category name, around the jump bar) is the panel's: forwarded,
    // the key area would take it for its nearest key (delete or ABC).
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}

    // MARK: Jump bar

    private func rebuildJumpBar() {
        for view in jumpBar.arrangedSubviews { view.removeFromSuperview() }
        for (index, section) in sections.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.accessibilityLabel = section.name
            button.accessibilityIdentifier = "lf.emoji.category.\(index)"
            button.addAction(UIAction { [weak self] _ in self?.jump(to: index) }, for: .touchUpInside)
            jumpBar.addArrangedSubview(button)
        }
        styleChrome()
    }

    private func styleChrome() {
        for case let button as UIButton in jumpBar.arrangedSubviews where sections.indices.contains(button.tag) {
            let shown = button.tag == shownSection
            let configuration = UIImage.SymbolConfiguration(pointSize: 15, weight: bold || shown ? .semibold : .regular)
            button.setImage(UIImage(systemName: sections[button.tag].symbol, withConfiguration: configuration), for: .normal)
            // The category shown takes the accent, as the keyboard marks every current state.
            button.tintColor = shown ? Self.shownTint : .secondaryLabel
            button.accessibilityTraits = button.tag == shownSection ? [.button, .selected] : .button
        }
    }

    private func jump(to section: Int) {
        guard sections.indices.contains(section), !sections[section].emoji.isEmpty else { return }
        UIDevice.current.playInputClick()
        grid.scrollToItem(at: IndexPath(item: 0, section: section), at: .left, animated: false)
        // Scrolled to its first item, the section's inset leaves its start a little right of the edge.
        grid.contentOffset.x = max(0, min(grid.contentOffset.x - flow.sectionInset.left,
                                          grid.contentSize.width - grid.bounds.width))
        show(section: section)
    }

    private func show(section: Int) {
        guard sections.indices.contains(section) else { return }
        shownSection = section
        styleChrome()
    }

    // MARK: Grid

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections[section].emoji.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: EmojiCell.reuseID, for: indexPath)
        (cell as? EmojiCell)?.configure(sections[indexPath.section].emoji[indexPath.item], side: flow.itemSize.height)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        onEmojiPressBegan?(sections[indexPath.section].emoji[indexPath.item])
    }

    /// The finger left the cell: a selection, if any, comes in this same turn of the run loop; after it, the press is
    /// over either way.
    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        DispatchQueue.main.async { [weak self] in self?.onEmojiPressCancelled?() }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        onEmoji?(sections[indexPath.section].emoji[indexPath.item])
    }

    /// An emoji was typed (at its release, or committed by a key's touch-down): it joins the recents.
    func emojiTyped(_ emoji: String) {
        recents.use(emoji)
        UserDefaults.standard.set(recents.emoji, forKey: Self.recentsKey)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onEmojiPressCancelled?()
    }

    /// The jump bar follows the section at the grid's left edge.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let probe = CGPoint(x: scrollView.contentOffset.x + flow.sectionInset.left + flow.itemSize.width / 2,
                            y: flow.itemSize.height / 2)
        if let path = grid.indexPathForItem(at: probe), path.section != shownSection { show(section: path.section) }
    }
}

private final class EmojiCell: UICollectionViewCell {
    static let reuseID = "emoji"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        contentView.addSubview(label)
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ emoji: String, side: CGFloat) {
        label.text = emoji
        label.font = .systemFont(ofSize: floor(side * 0.74))
        accessibilityLabel = emoji
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds
    }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? KeyPalette.pressedFill.withAlphaComponent(0.6) : .clear }
    }
}
