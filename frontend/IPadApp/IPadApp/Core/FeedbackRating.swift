import Foundation

struct FeedbackRatingEntry: Codable, Equatable {
    var stars: Int
    var reason: String
    var updatedAt: Date
}

struct FeedbackRatingState: Codable, Equatable {
    var enabled: Bool
    var feedbackId: String?
    var rating: FeedbackRatingEntry?
}

struct FeedbackRatingWrite: Codable, Equatable {
    var jobId: UUID
    var feedbackId: String
    var stars: Int
    var reason: String
}
