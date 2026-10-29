// swiftc Shared/StreamFormat.swift Tests/PeerByteWindowCheck.swift -o /tmp/peer-window-check
import Foundation
@main enum Check {
    static func main() {
        var sender = PeerByteWindow()
        precondition(!sender.sent(1))
        precondition(!sender.announce(0) && !sender.announce(1_048_577))
        precondition(sender.announce(PeerByteWindow.capacity))
        precondition(!sender.announce(PeerByteWindow.capacity))
        for _ in 0..<32 { precondition(sender.sent(8192)) }
        precondition(sender.available == 0 && sender.outstanding == PeerByteWindow.capacity)
        precondition(!sender.sent(1), "A stalled receiver must prevent the next byte from being sent")
        precondition(sender.acknowledge(4096))
        precondition(!sender.sent(8192) && sender.sent(4096))
        precondition(!sender.acknowledge(-1) && !sender.acknowledge(PeerByteWindow.capacity + 1))
        precondition(sender.acknowledge(PeerByteWindow.capacity))
        precondition(!sender.acknowledge(1), "Duplicate acknowledgement manufactured credits")
        for _ in 0..<2048 {
            precondition(sender.sent(8192))
            precondition(sender.acknowledge(8192))
            precondition(sender.available + sender.outstanding == sender.limit)
        }
        precondition(sender.available == PeerByteWindow.capacity && sender.outstanding == 0)
        print("PASS bounded burst, paused sender, partial acknowledgement, resumed transfer, invalid/duplicate credit rejection")
    }
}
