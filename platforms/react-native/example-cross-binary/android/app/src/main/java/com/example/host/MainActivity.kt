package com.example.host

import com.facebook.react.ReactActivity
import com.facebook.react.ReactActivityDelegate
import com.facebook.react.defaults.DefaultReactActivityDelegate

class MainActivity : ReactActivity() {

    // Phải match `AppRegistry.registerComponent('UniTrackRNHost', ...)` ở
    // rn/index.js. Sai tên → bridge sẽ throw "Application UniTrackRNHost has
    // not been registered".
    override fun getMainComponentName(): String = "UniTrackRNHost"

    override fun createReactActivityDelegate(): ReactActivityDelegate {
        return DefaultReactActivityDelegate(this, mainComponentName, false)
    }
}
