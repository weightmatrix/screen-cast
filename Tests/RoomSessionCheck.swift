import Foundation

// Isolated room-state check: never requests hardware microphone capture.
final class RoomAudioSettings {
    static let shared = RoomAudioSettings()
    func restoreReceiverMicrophone() {}
}

@main enum RoomSessionCheck {
    static func main() {
        let room = RoomSession.shared
        var first: [[String: Any]] = [], second: [[String: Any]] = []
        room.attach("first", host: true) { first.append($0); return true }
        room.attach("second", host: true) { second.append($0); return true }
        let alice = UUID().uuidString, bob = UUID().uuidString
        room.receive(["kind":"hello", "participant":alice, "nickname":"Alice", "origin":"publicWeb"], from:"first")
        room.receive(["kind":"hello", "participant":bob, "nickname":"Bob", "origin":"appLocalCode"], from:"second")
        precondition(room.peerOrigins["first"] == "公网网页" && room.peerOrigins["second"] == "app局域网邀请码")
        room.receive(["kind":"hello", "participant":bob, "nickname":"Bob", "origin":"not-allowed"], from:"second")
        precondition(room.peerOrigins["second"] == "app局域网邀请码")
        let id = UUID().uuidString
        room.receive(["kind":"chat", "id":id, "author":"Spoofed owner", "text":"Synthetic group message"], from:"first")
        precondition(room.messages.count == 1 && room.messages[0].author == "Alice")
        precondition(first.last?["text"] as? String == "Synthetic group message" && second.last?["author"] as? String == "Alice")
        room.receive(["kind":"chat", "id":id, "text":"replay"], from:"first")
        precondition(room.messages.count == 1)
        room.receive(["kind":"chat", "id":UUID().uuidString, "text":String(repeating:"x", count:501)], from:"second")
        precondition(room.messages.count == 1)
        for n in 0..<12 { room.receive(["kind":"chat", "id":UUID().uuidString, "text":"Rate fixture \(n)"], from:"second") }
        precondition(room.messages.count == 9, "At most eight messages per peer per ten seconds")
        precondition(room.send("Synthetic owner message")); precondition(room.messages.last?.author == room.nickname)
        room.detach("first"); room.detach("second"); precondition(room.messages.isEmpty)

        precondition(room.peerOrigins.isEmpty && room.peerNicknames.isEmpty)
        room.attach("unnamed", host: true) { _ in true }
        let guest = UUID().uuidString
        room.receive(["kind":"hello", "participant":guest, "nickname":""], from:"unnamed")
        precondition(room.peerNicknames["unnamed"] == "访客·" + guest.prefix(4).uppercased())
        room.detach("unnamed")

        let mixer = VoiceRoom.shared
        mixer.setEnabled(true)
        mixer.identify("alice-1", participant:"alice"); mixer.identify("alice-2", participant:"alice"); mixer.identify("bob", participant:"bob")
        precondition(mixer.append("alice-1", pcm:[Int16](repeating:1000, count:480)))
        precondition(!mixer.append("alice-2", pcm:[Int16](repeating:1000, count:480)), "Do not duplicate a participant across streams")
        precondition(mixer.append("bob", pcm:[Int16](repeating:2000, count:480)))
        precondition(mixer.mix(excluding:"alice-1", frames:480).allSatisfy { $0 == 2000 }, "Alice must not hear herself")
        precondition(mixer.mix(excluding:"bob", frames:480).allSatisfy { $0 == 1000 })
        precondition(mixer.mix(excluding:"owner", frames:480).allSatisfy { $0 == 3000 })
        mixer.setEnabled(false)
        precondition(!mixer.append("bob", pcm:[1,2,3]))
        precondition(mixer.mix(excluding:"owner", frames:480).allSatisfy { $0 == 0 })
        mixer.remove("alice-1"); mixer.remove("alice-2"); mixer.remove("bob")
        print("PASS common room broadcast, nickname binding, bounds/rate/replay, ephemeral history, mix-minus, duplicate suppression and owner voice mute")
    }
}
