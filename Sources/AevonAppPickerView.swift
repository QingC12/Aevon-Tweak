import UIKit

/// 面板里的一个字母分组
private struct AevonAppSection {
    let letter: String
    var apps: [AevonAppEntry]
}

/// 应用选择面板：挂在悬浮球所在窗口里的普通视图（不用 present，
/// 避免在我们的非 key 窗口上做模态呈现而抢走 SpringBoard 的焦点）。
///
/// V0.0.14：
///   ①顶部「已开窗口」条 —— 点名称把窗口提到最前，点 ✕ 关闭单个，右侧可一键全关；
///   ②「单窗 / 左右分屏」两档 —— 分屏档连选两个 App，自动开成左右并排；
///   ③按拼音首字母分组 + 右侧索引条，75 个 App 不用一路划到底。
///   刻意不做搜索框：跨窗口的文本输入要抢 SpringBoard 的键盘焦点，风险高于收益。
final class AevonAppPickerView: UIView, UITableViewDataSource, UITableViewDelegate {
    private let dimView = UIView()
    private let panel = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let modeControl = UISegmentedControl(items: ["单窗", "左右分屏"])
    private let openScroll = UIScrollView()
    private let openEmptyLabel = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    private var apps: [AevonAppEntry] = []
    private var sections: [AevonAppSection] = []
    private var chips: [UIView] = []
    /// 分屏档下已选中的左侧 App
    private var splitFirst: AevonAppEntry?

    private let onClose: () -> Void

    private let dimHeight: CGFloat = 30

    init(apps: [AevonAppEntry], onClose: @escaping () -> Void) {
        self.apps = apps
        self.onClose = onClose
        super.init(frame: UIScreen.main.bounds)

        backgroundColor = .clear
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        dimView.backgroundColor = UIColor(white: 0, alpha: 0.45)
        addSubview(dimView)
        dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(closeTapped)))

        panel.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        panel.layer.cornerRadius = 16
        panel.clipsToBounds = true
        addSubview(panel)

        titleLabel.text = "选择要浮窗打开的 App"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        panel.addSubview(titleLabel)

        subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        panel.addSubview(subtitleLabel)

        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(UIColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1.0), for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        panel.addSubview(closeButton)

        modeControl.selectedSegmentIndex = 0
        modeControl.selectedSegmentTintColor = UIColor(red: 0.20, green: 0.45, blue: 0.92, alpha: 1.0)
        modeControl.backgroundColor = UIColor(white: 0.18, alpha: 1.0)
        modeControl.setTitleTextAttributes([NSAttributedString.Key.foregroundColor: UIColor.white], for: .selected)
        modeControl.setTitleTextAttributes([NSAttributedString.Key.foregroundColor: UIColor(white: 0.75, alpha: 1.0)],
                                           for: .normal)
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        panel.addSubview(modeControl)

        openScroll.showsHorizontalScrollIndicator = false
        openScroll.backgroundColor = .clear
        panel.addSubview(openScroll)

        openEmptyLabel.text = "暂无已开窗口"
        openEmptyLabel.textColor = UIColor(white: 0.45, alpha: 1.0)
        openEmptyLabel.font = UIFont.systemFont(ofSize: 12)
        panel.addSubview(openEmptyLabel)

        table.backgroundColor = .clear
        table.separatorColor = UIColor(white: 0.22, alpha: 1.0)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 54
        table.sectionIndexColor = UIColor(white: 0.55, alpha: 1.0)
        table.sectionIndexBackgroundColor = .clear
        table.sectionIndexTrackingBackgroundColor = UIColor(white: 0.2, alpha: 0.6)
        panel.addSubview(table)

        emptyLabel.text = apps.isEmpty
            ? "没有读到用户 App（可能是权限或接口变化），\n请把 /var/mobile/Aevon.log 发给作者"
            : ""
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = UIColor(white: 0.6, alpha: 1.0)
        emptyLabel.font = UIFont.systemFont(ofSize: 14)
        panel.addSubview(emptyLabel)

        buildSections()
        refreshChips()
        updateHeaders()
        AevonLog.info("[面板] 应用选择面板已创建（\(apps.count) 项，\(sections.count) 个字母分组，"
            + "已开窗口 \(AevonWindowManager.openBundleIDs.count) 个）")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        dimView.frame = bounds

        let width = min(bounds.width - 32, 460)
        let height = min(bounds.height * 0.72, 620)
        panel.frame = CGRect(x: (bounds.width - width) / 2,
                             y: (bounds.height - height) / 2,
                             width: width,
                             height: height)

        titleLabel.frame = CGRect(x: 18, y: 12, width: width - 100, height: 22)
        subtitleLabel.frame = CGRect(x: 18, y: 34, width: width - 100, height: 16)
        closeButton.frame = CGRect(x: width - 76, y: 10, width: 60, height: 40)
        modeControl.frame = CGRect(x: 16, y: 56, width: width - 32, height: 32)

        let hasOpen = !chips.isEmpty
        openScroll.isHidden = !hasOpen
        openEmptyLabel.isHidden = hasOpen
        openScroll.frame = CGRect(x: 16, y: 96, width: width - 32, height: dimHeight)
        openEmptyLabel.frame = CGRect(x: 18, y: 96, width: width - 36, height: dimHeight)
        layoutChips()

        let tableTop: CGFloat = 132
        table.frame = CGRect(x: 0, y: tableTop, width: width, height: max(0, height - tableTop))
        emptyLabel.frame = CGRect(x: 20, y: height / 2 - 40, width: width - 40, height: 80)
    }

    // MARK: - 头部文案

    private func updateHeaders() {
        if modeControl.selectedSegmentIndex == 1 {
            if let first = splitFirst {
                titleLabel.text = "左右分屏：选右边的 App"
                subtitleLabel.text = "左边：\(first.name)　再点一个 App 完成分屏（再点自己不取消）"
            } else {
                titleLabel.text = "左右分屏：先选左边的 App"
                subtitleLabel.text = "共 \(apps.count) 个用户 App　选好后会自动再开右边"
            }
        } else {
            titleLabel.text = "选择要浮窗打开的 App"
            subtitleLabel.text = "共 \(apps.count) 个用户 App"
        }
        table.reloadData()
    }

    @objc private func modeChanged() {
        splitFirst = nil
        AevonLog.info("[面板] 切换到\(modeControl.selectedSegmentIndex == 1 ? "左右分屏" : "单窗")模式")
        updateHeaders()
    }

    // MARK: - 已开窗口条

    private func refreshChips() {
        let ids = AevonWindowManager.openBundleIDs
        for chip in chips { chip.removeFromSuperview() }
        chips.removeAll()

        for bundleID in ids {
            let chip = makeChip(title: AevonWindowManager.title(for: bundleID), bundleID: bundleID)
            openScroll.addSubview(chip)
            chips.append(chip)
        }
        if chips.count > 1 {
            let closeAll = makeCloseAllChip(count: chips.count)
            openScroll.addSubview(closeAll)
            chips.append(closeAll)
        }
        setNeedsLayout()
    }

    private func chipWidth(for title: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: 12, weight: .medium)
        let textWidth = (title as NSString).size(withAttributes: [NSAttributedString.Key.font: font]).width
        return min(180, textWidth.rounded(.up) + 40)
    }

    private func makeChip(title: String, bundleID: String) -> UIView {
        let width = chipWidth(for: title)
        let chip = UIView(frame: CGRect(x: 0, y: 0, width: width, height: dimHeight))
        chip.backgroundColor = UIColor(white: 0.20, alpha: 1.0)
        chip.layer.cornerRadius = dimHeight / 2

        let name = UIButton(type: .system, primaryAction: UIAction(title: title) { [weak self] _ in
            AevonLog.info("[面板] 置顶已开窗口 \(bundleID)")
            AevonWindowManager.bringToFront(bundleID: bundleID)
            self?.closeTapped()
        })
        name.frame = CGRect(x: 10, y: 0, width: width - 34, height: dimHeight)
        name.setTitle(title, for: .normal)
        name.setTitleColor(.white, for: .normal)
        name.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        name.titleLabel?.lineBreakMode = .byTruncatingTail
        name.contentHorizontalAlignment = .left
        chip.addSubview(name)

        let x = UIButton(type: .system, primaryAction: UIAction(title: "✕") { [weak self] _ in
            AevonLog.info("[面板] 从面板关闭 \(bundleID)")
            AevonWindowManager.close(bundleID: bundleID)
            self?.refreshChips()
        })
        x.frame = CGRect(x: width - 28, y: 0, width: 24, height: dimHeight)
        x.setTitle("✕", for: .normal)
        x.setTitleColor(UIColor(white: 0.7, alpha: 1.0), for: .normal)
        x.titleLabel?.font = UIFont.systemFont(ofSize: 11, weight: .semibold)
        chip.addSubview(x)

        return chip
    }

    private func makeCloseAllChip(count: Int) -> UIView {
        let title = "全部关闭 (\(count))"
        let width = chipWidth(for: title)
        let chip = UIView(frame: CGRect(x: 0, y: 0, width: width, height: dimHeight))
        chip.backgroundColor = UIColor(red: 0.45, green: 0.16, blue: 0.16, alpha: 1.0)
        chip.layer.cornerRadius = dimHeight / 2
        let button = UIButton(type: .system, primaryAction: UIAction(title: title) { [weak self] _ in
            AevonLog.info("[面板] 一键关闭全部窗口")
            AevonWindowManager.closeAll()
            self?.refreshChips()
        })
        button.frame = CGRect(x: 6, y: 0, width: width - 12, height: dimHeight)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        chip.addSubview(button)
        return chip
    }

    private func layoutChips() {
        var x: CGFloat = 0
        for chip in chips {
            let width = chip.frame.width
            chip.frame = CGRect(x: x, y: 0, width: width, height: dimHeight)
            x += width + 8
        }
        openScroll.contentSize = CGSize(width: max(0, x - 8), height: dimHeight)
    }

    // MARK: - 关闭

    @objc private func closeTapped() {
        onClose()
        removeFromSuperview()
    }

    // MARK: - 字母分组

    /// 取名称的拼音首字母；英文数字直接首字符，其余归到 "#"。
    private static func initialLetter(_ name: String) -> String {
        guard let first = name.first else { return "#" }
        let head = String(first)
        if let upper = head.uppercased().first, upper.isASCII, upper >= "A", upper <= "Z" {
            return String(upper)
        }
        let latin = head.applyingTransform(.mandarinToLatin, reverse: false) ?? ""
        let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        if let upper = plain.uppercased().first, upper.isASCII, upper >= "A", upper <= "Z" {
            return String(upper)
        }
        return "#"
    }

    private func buildSections() {
        var buckets: [String: [AevonAppEntry]] = [:]
        for entry in apps {
            let letter = AevonAppPickerView.initialLetter(entry.name)
            buckets[letter, default: []].append(entry)
        }
        let letters = buckets.keys.sorted { a, b in
            if a == "#" { return false }
            if b == "#" { return true }
            return a < b
        }
        sections = letters.map { letter in
            AevonAppSection(letter: letter, apps: (buckets[letter] ?? []).sorted { $0.name < $1.name })
        }
    }

    // MARK: - 表格

    func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard section < sections.count else { return 0 }
        return sections[section].apps.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard section < sections.count else { return nil }
        return sections[section].letter
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard section < sections.count else { return nil }
        let container = UIView()
        container.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
        let label = UILabel(frame: CGRect(x: 16, y: 2, width: 60, height: 16))
        label.text = sections[section].letter
        label.textColor = UIColor(white: 0.55, alpha: 1.0)
        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
        container.addSubview(label)
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 20
    }

    func sectionIndexTitles(for tableView: UITableView) -> [String]? {
        return sections.count > 6 ? sections.map { $0.letter } : nil
    }

    func tableView(_ tableView: UITableView, sectionForSectionIndexTitle title: String, at index: Int) -> Int {
        return index
    }

    private func entry(at indexPath: IndexPath) -> AevonAppEntry? {
        guard indexPath.section < sections.count else { return nil }
        let rows = sections[indexPath.section].apps
        guard indexPath.row < rows.count else { return nil }
        return rows[indexPath.row]
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "AevonAppCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        guard let entry = entry(at: indexPath) else { return cell }
        cell.backgroundColor = .clear
        cell.textLabel?.text = entry.name
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        cell.detailTextLabel?.text = entry.bundleID
        cell.detailTextLabel?.textColor = UIColor(white: 0.55, alpha: 1.0)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 11)
        cell.selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = UIColor(white: 0.25, alpha: 1.0)
        cell.selectedBackgroundView = selected

        // 分屏档：已选中的左侧 App 打勾，已开窗的 App 显示「已开」
        if let first = splitFirst, first.bundleID == entry.bundleID {
            cell.accessoryType = .checkmark
            cell.accessoryView = nil
            cell.tintColor = UIColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1.0)
        } else if AevonWindowManager.isWindowed(entry.bundleID) {
            cell.accessoryType = .none
            let tag = UILabel(frame: CGRect(x: 0, y: 0, width: 40, height: 20))
            tag.text = "已开"
            tag.textColor = UIColor(white: 0.5, alpha: 1.0)
            tag.font = UIFont.systemFont(ofSize: 11)
            tag.textAlignment = .right
            cell.accessoryView = tag
        } else {
            cell.accessoryType = .none
            cell.accessoryView = nil
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let entry = entry(at: indexPath) else { return }

        if modeControl.selectedSegmentIndex == 1 {
            handleSplitSelection(entry)
            return
        }

        AevonLog.info("[面板] 选中 \(entry.name) (\(entry.bundleID))")
        closeTapped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            AevonWindowManager.launchAndOpen(bundleID: entry.bundleID)
        }
    }

    /// 分屏档：第一次点选左边，第二次点选右边并立即开成并排。
    private func handleSplitSelection(_ entry: AevonAppEntry) {
        guard let first = splitFirst else {
            splitFirst = entry
            AevonLog.info("[面板] 左右分屏已选定左侧 \(entry.name) (\(entry.bundleID))")
            updateHeaders()
            return
        }
        if first.bundleID == entry.bundleID {
            // 再点自己 = 取消选择
            splitFirst = nil
            AevonLog.info("[面板] 已取消左侧选择")
            updateHeaders()
            return
        }

        AevonLog.info("[面板] 左右分屏已选定右侧 \(entry.name) (\(entry.bundleID))")
        let left = first.bundleID
        let right = entry.bundleID
        splitFirst = nil
        closeTapped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            AevonWindowManager.openSplit(left: left, right: right)
        }
    }
}
