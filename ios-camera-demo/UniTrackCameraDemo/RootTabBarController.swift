// RootTabBarController.swift — five tabs exercising the camera taxonomy.

import UIKit

final class RootTabBarController: UITabBarController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let b2c = UINavigationController(rootViewController: CameraListViewController())
        b2c.tabBarItem = UITabBarItem(title: "Cameras", image: UIImage(systemName: "video"), tag: 0)

        let vms = UINavigationController(rootViewController: VMSViewController())
        vms.tabBarItem = UITabBarItem(title: "VMS", image: UIImage(systemName: "rectangle.grid.2x2"), tag: 1)

        let onboarding = UINavigationController(rootViewController: PairingViewController())
        onboarding.tabBarItem = UITabBarItem(title: "Add Camera", image: UIImage(systemName: "plus.viewfinder"), tag: 2)

        let notif = UINavigationController(rootViewController: NotificationsViewController())
        notif.tabBarItem = UITabBarItem(title: "Alerts", image: UIImage(systemName: "bell"), tag: 3)

        let settings = UINavigationController(rootViewController: SettingsViewController())
        settings.tabBarItem = UITabBarItem(title: "Settings", image: UIImage(systemName: "gearshape"), tag: 4)

        viewControllers = [b2c, vms, onboarding, notif, settings]
    }
}
