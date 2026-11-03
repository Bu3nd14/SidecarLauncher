// snap — one read-only snapshot of what Universal Control depends on.
// Prints one line per online display, then the Wi-Fi association.
// It changes nothing: no CGBeginDisplayConfiguration, no CoreWLAN setters.
import CoreGraphics
import CoreWLAN
import Foundation

var n: UInt32 = 0
CGGetOnlineDisplayList(0, nil, &n)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
CGGetOnlineDisplayList(n, &ids, &n)

for id in ids.prefix(Int(n)) {
    let vendor = "0x" + String(CGDisplayVendorNumber(id), radix: 16)
    let main = CGDisplayIsMain(id) != 0
    let builtin = CGDisplayIsBuiltin(id) != 0
    let active = CGDisplayIsActive(id) != 0
    let mirrorOf = CGDisplayMirrorsDisplay(id)   // kCGNullDirectDisplay (0) when not mirroring
    let b = CGDisplayBounds(id)
    print("display id=\(id) vendor=\(vendor) builtin=\(builtin) main=\(main) active=\(active) mirror_of=\(mirrorOf) origin=\(Int(b.origin.x)),\(Int(b.origin.y)) size=\(Int(b.width))x\(Int(b.height))")
}

let wifi = CWWiFiClient.shared().interface()
let ch = wifi?.wlanChannel()
let band: String
switch ch?.channelBand {
case .band2GHz?: band = "2.4GHz"
case .band5GHz?: band = "5GHz"
case .band6GHz?: band = "6GHz"
default: band = "?"
}
print("wifi on=\(wifi?.powerOn() ?? false) channel=\(ch?.channelNumber ?? 0) band=\(band) rssi=\(wifi?.rssiValue() ?? 0)")
