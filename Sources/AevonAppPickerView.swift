import UIKit

/// 应用选择面板：挂在悬浮球所在窗口里的普通视图（不用 present，
/// 避免在我们的非 key 窗口上做模态呈现而抢走 SpringBoard 的焦点）。
final class AevonAppPickerView: UIView, UITableViewDataSource, UITableViewDelegate {
    private let dimView = UIView()
    private let panel = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    private var apps: [AevonAppEntry] = []
    private let onClose: () -> Void

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

        subtitleLabel.text = "共 \(apps.count) 个用户 App"
        subtitleLabel.textColor = UIColor(white: 0.65, alpha: 1.0)
        subtitleLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        panel.addSubview(subtitleLabel)

        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(UIColor(red: 0.35, green: 0.62, blue: 1.0, alpha: 1.0), for: .normal)
        closeButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        panel.addSubview(closeButton)

        table.backgroundColor = .clear
        table.separatorColor = UIColor(white: 0.22, alpha: 1.0)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 54
        panel.addSubview(table)

        emptyLabel.text = apps.isEmpty
            ? "没有读到用户 App（可能是权限或接口变化），\n请把 /var/mobile/Aevon.log 发给作者"
            : ""
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = UIColor(white: 0.6, alpha: 1.0)
        emptyLabel.font = UIFont.systemFont(ofSize: 14)
        panel.addSubview(emptyLabel)

        AevonLog.info("[面板] 应用选择面板已创建（\(apps.count) 项）")
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

        titleLabel.frame = CGRect(x: 18, y: 14, width: width - 100, height: 22)
        subtitleLabel.frame = CGRect(x: 18, y: 38, width: width - 100, height: 16)
        closeButton.frame = CGRect(x: width - 76, y: 14, width: 60, height: 40)
        table.frame = CGRect(x: 0, y: 62, width: width, height: height - 62)
        emptyLabel.frame = CGRect(x: 20, y: height / 2 - 40, width: width - 40, height: 80)
    }

    // MARK: - 关闭

    @objc private func closeTapped() {
        onClose()
        removeFromSuperview()
    }

    // MARK: - 表格

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return apps.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "AevonAppCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        guard indexPath.row < apps.count else { return cell }
        let entry = apps[indexPath.row]
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
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < apps.count else { return }
        let entry = apps[indexPath.row]
        AevonLog.info("[面板] 选中 \(entry.name) (\(entry.bundleID))")
        closeTapped()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            AevonWindowManager.launchAndOpen(bundleID: entry.bundleID)
        }
    }
}
