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
    /// V0.2.10（AevonPickerBeautyV210）：面板底改成毛玻璃 + 半透明深色叠加。
    /// 原来是一块纯色 #1C1C1E，压在圆盘 / 桌面上像贴了一张纸；现在能透出背景的
    /// 一点点颜色和亮度，圆角也收到 22（原来是 16，直角感重）。
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemChromeMaterialDark))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let openScroll = UIScrollView()
    private let openEmptyLabel = UILabel()
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    private var apps: [AevonAppEntry] = []
    private var sections: [AevonAppSection] = []
    private var chips: [UIView] = []

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

        panel.backgroundColor = UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 0.82)
        panel.layer.cornerRadius = 22
        panel.layer.cornerCurve = .continuous
        panel.layer.borderWidth = 0.5
        panel.layer.borderColor = UIColor(white: 1.0, alpha: 0.14).cgColor
        panel.clipsToBounds = true
        addSubview(panel)

        // 毛玻璃垫在最底层；它不接触摸（否则会挡住 table 的行选中）
        blurView.isUserInteractionEnabled = false
        panel.addSubview(blurView)

        titleLabel.text = "选择要浮窗打开的 App"
        titleLabel.textColor = .white
        titleLabel.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        panel.addSubview(titleLabel)

        subtitleLabel.textColor = UIColor(white: 0.62, alpha: 1.0)
        subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        panel.addSubview(subtitleLabel)

        // V0.2.10（AevonPickerBeautyV210）：关闭按钮改成右上角圆形 ✕（系统符号），
        // 比原来那行蓝色「关闭」文字更像面板自己的把手，也不会和标题抢视线。
        let closeConfig = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: closeConfig), for: .normal)
        closeButton.setTitle(nil, for: .normal)
        closeButton.tintColor = UIColor(white: 0.93, alpha: 1.0)
        closeButton.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        closeButton.layer.cornerRadius = 15
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        panel.addSubview(closeButton)

        openScroll.showsHorizontalScrollIndicator = false
        openScroll.backgroundColor = .clear
        panel.addSubview(openScroll)

        openEmptyLabel.text = "暂无已开窗口"
        openEmptyLabel.textColor = UIColor(white: 0.45, alpha: 1.0)
        openEmptyLabel.font = UIFont.systemFont(ofSize: 12)
        panel.addSubview(openEmptyLabel)

        table.backgroundColor = .clear
        table.separatorColor = UIColor(white: 1.0, alpha: 0.10)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 60
        // V0.2.10（AevonPickerBeautyV210）：分隔线从文字开头起画（图标左边留白），
        // 视觉上和系统的设置列表一致，不再是「一条横贯整行的白线」。
        table.separatorInset = UIEdgeInsets(top: 0, left: 66, bottom: 0, right: 16)
        table.sectionIndexColor = UIColor(white: 0.62, alpha: 1.0)
        table.sectionIndexBackgroundColor = .clear
        table.sectionIndexTrackingBackgroundColor = UIColor(white: 1.0, alpha: 0.10)
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
            + "已开窗口 \(AevonWindowManager.openBundleIDs.count) 个）（AevonPanelSimpleV30）")
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
        blurView.frame = panel.bounds

        titleLabel.frame = CGRect(x: 20, y: 14, width: width - 74, height: 22)
        subtitleLabel.frame = CGRect(x: 20, y: 38, width: width - 74, height: 16)
        closeButton.frame = CGRect(x: width - 46, y: 14, width: 30, height: 30)
        let hasOpen = !chips.isEmpty
        openScroll.isHidden = !hasOpen
        openEmptyLabel.isHidden = hasOpen
        openScroll.frame = CGRect(x: 16, y: 56, width: width - 32, height: dimHeight)
        openEmptyLabel.frame = CGRect(x: 18, y: 56, width: width - 36, height: dimHeight)
        layoutChips()

        let tableTop: CGFloat = 92
        table.frame = CGRect(x: 0, y: tableTop, width: width, height: max(0, height - tableTop))
        emptyLabel.frame = CGRect(x: 20, y: height / 2 - 40, width: width - 40, height: 80)
    }

    // MARK: - 头部文案

    private func updateHeaders() {
        // V0.0.30（AevonPanelSimpleV30）：面板只保留「选 App 开浮窗」一件事
        titleLabel.text = "选择要浮窗打开的 App"
        subtitleLabel.text = "共 \(apps.count) 个 App（含系统 App）"
        table.reloadData()
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
        // V0.2.10（AevonPickerBeautyV210）：胶囊改成半透明白（原来是不透明灰），
        // 压在毛玻璃上才有「玻璃上的小标签」质感。
        chip.backgroundColor = UIColor(white: 1.0, alpha: 0.14)
        chip.layer.cornerRadius = dimHeight / 2
        chip.layer.borderWidth = 0.5
        chip.layer.borderColor = UIColor(white: 1.0, alpha: 0.10).cgColor

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
        // V0.2.10（AevonPickerBeautyV210）：分组标题原来刷了一块不透明深色条，
        // 压在毛玻璃上像补丁；改成透明，只留小号字母。
        container.backgroundColor = .clear
        let label = UILabel(frame: CGRect(x: 20, y: 4, width: 60, height: 16))
        label.text = sections[section].letter
        label.textColor = UIColor(white: 0.60, alpha: 1.0)
        label.font = UIFont.systemFont(ofSize: 12, weight: .bold)
        container.addSubview(label)
        return container
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return 22
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
        // V0.0.22：每一行显示 App 原生图标（取不到时返回 nil，自动退回纯文字）
        cell.imageView?.image = AevonAppIcon.image(bundleID: entry.bundleID, size: 38)
        cell.imageView?.contentMode = .scaleAspectFit
        cell.textLabel?.text = entry.name
        cell.textLabel?.textColor = .white
        cell.textLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        cell.detailTextLabel?.text = entry.bundleID
        cell.detailTextLabel?.textColor = UIColor(white: 0.50, alpha: 1.0)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 11)
        cell.selectionStyle = .default
        let selected = UIView()
        selected.backgroundColor = UIColor(white: 1.0, alpha: 0.12)
        cell.selectedBackgroundView = selected

        // V0.0.30：面板只有单窗模式 —— 已开窗的 App 显示「已开」标签
        if AevonWindowManager.isWindowed(entry.bundleID) {
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

        AevonLog.info("[面板] 选中 \(entry.name) (\(entry.bundleID))")
        closeTapped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            AevonWindowManager.launchAndOpen(bundleID: entry.bundleID)
        }
    }

}
