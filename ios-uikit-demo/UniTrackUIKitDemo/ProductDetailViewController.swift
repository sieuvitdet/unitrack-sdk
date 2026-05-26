// ProductDetailViewController — plain UIKit. No tracking code.
//
// Auto-captured: screen_view (uses the navigation title = product name) and a
// tap for the "Thêm vào giỏ" button (keyed by accessibilityIdentifier).

import UIKit

final class ProductDetailViewController: UIViewController {

    var productName: String = "Sản phẩm"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = productName
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.text = productName
        label.font = .boldSystemFont(ofSize: 22)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        var cfg = UIButton.Configuration.filled()
        cfg.title = "Thêm vào giỏ"
        let addBtn = UIButton(configuration: cfg)
        addBtn.accessibilityIdentifier = "detail_add_to_cart"
        addBtn.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(label)
        view.addSubview(addBtn)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            addBtn.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            addBtn.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
        ])
    }
}
