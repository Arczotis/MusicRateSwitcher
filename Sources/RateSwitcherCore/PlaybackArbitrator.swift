import Foundation

public enum PlaybackArbitrator {
    public static func preferredDetection(
        from detections: [DetectedSourceFormat],
        enabledPlayers: Set<MusicPlayerID>,
        outputActivity: [MusicPlayerID: Bool],
        activitySupported: Bool
    ) -> DetectedSourceFormat? {
        let enabled = detections.filter { enabledPlayers.contains($0.player) }
        let eligible: [DetectedSourceFormat]
        if activitySupported {
            eligible = enabled.filter { outputActivity[$0.player] == true }
        } else {
            eligible = enabled
        }
        return eligible.max(by: { $0.detectedAt < $1.detectedAt })
    }
}
