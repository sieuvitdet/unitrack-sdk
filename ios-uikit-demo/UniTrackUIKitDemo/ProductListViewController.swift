// ProductListViewController — plain UIKit table. No tracking code.
//
// Auto-captured: screen_view "Sản phẩm" on appear. Row taps are UITableView
// selections (not UIControl), so to keep the demo focused on UIControl tap
// capture, each row pushes a detail screen — which itself emits screen_view.

import UIKit

final class ProductListViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let items = ["Áo thun Mobix", "Bình giữ nhiệt", "Tai nghe", "Sạc dự phòng"]
    private let table = UITableView()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Sản phẩm"
        view.backgroundColor = .systemBackground
        table.frame = view.bounds
        table.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        table.dataSource = self
        table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "c")
        view.addSubview(table)
    }

    func tableView(_ t: UITableView, numberOfRowsInSection s: Int) -> Int { items.count }

    func tableView(_ t: UITableView, cellForRowAt i: IndexPath) -> UITableViewCell {
        let cell = t.dequeueReusableCell(withIdentifier: "c", for: i)
        cell.textLabel?.text = items[i.row]
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ t: UITableView, didSelectRowAt i: IndexPath) {
        t.deselectRow(at: i, animated: true)
        let vc = ProductDetailViewController()
        vc.productName = items[i.row]
        navigationController?.pushViewController(vc, animated: true)
    }
}
