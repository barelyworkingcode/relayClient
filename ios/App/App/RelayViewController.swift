import UIKit
import Capacitor

class RelayViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(SSLTrustPlugin())
        bridge?.registerPluginInstance(EveVoicePlugin())
    }
}
