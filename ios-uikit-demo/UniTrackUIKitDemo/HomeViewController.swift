// HomeViewController — plain UIKit. No tracking code.
//
// The SDK auto-captures:
//   • screen_view "Home" when this appears (viewDidAppear swizzle)
//   • a tap event for each button below (sendAction swizzle), keyed by the
//     button's accessibilityIdentifier (or its title if none is set)

import UIKit

final class HomeViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home"
        view.backgroundColor = .systemBackground

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
        ])

        // Each button has a stable accessibilityIdentifier -> becomes the tap key.
        stack.addArrangedSubview(makeButton(
            title: "Xem sản phẩm", id: "home_open_products",
            action: #selector(openProducts)))
        stack.addArrangedSubview(makeButton(
            title: "Gọi API (thành công)", id: "home_call_api_ok",
            action: #selector(callApiOk)))
        stack.addArrangedSubview(makeButton(
            title: "Gọi API (lỗi 404)", id: "home_call_api_404",
            action: #selector(callApi404)))
        // This one has NO identifier -> the SDK falls back to the button title.
        stack.addArrangedSubview(makeButton(
            title: "Nút không có ID", id: nil,
            action: #selector(noop)))
    }

    private func makeButton(title: String, id: String?, action: Selector) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.title = title
        let b = UIButton(configuration: cfg)
        b.accessibilityIdentifier = id
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    @objc private func openProducts() {
        navigationController?.pushViewController(ProductListViewController(), animated: true)
    }

    @objc private func callApiOk() {
        URLSession.shared.dataTask(
            with: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
        ) { _, resp, _ in
            print("API ok: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }.resume()
    }

    @objc private func callApi404() {
        URLSession.shared.dataTask(
            with: URL(string: "https://jsonplaceholder.typicode.com/nope-404")!
        ) { _, resp, _ in
            print("API 404: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }.resume()
    }

    @objc private func noop() {}
}
