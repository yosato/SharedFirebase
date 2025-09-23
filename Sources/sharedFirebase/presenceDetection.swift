//
//  File.swift
//  SharedFirebase
//
//  Created by Yo Sato on 2025/09/22.
//

import Foundation

public protocol MemberRepresentable {
    var uid: String { get }
    var displayName: String { get }
}

// Presence values you can show in UI
public enum PresenceState: Equatable {
    case online
    case background
    case offline
    case unknown
}

// What observers receive
public struct PresenceSnapshot: Equatable {
    public let uid: String
    public let state: PresenceState
    public let lastSeen: Date?
    public var isOnline: Bool {
        guard let t = lastSeen else { return false }
        return Date().timeIntervalSince(t) < 45 && state != .offline
    }
}

// Manager writes *your* presence; Observer watches *others*
public protocol PresenceManaging {
    func start_tracking(uid: String, device_id: String?, app_version: String?)
    func stop_tracking()
    func mark_background()
    func mark_foreground()
}

public protocol PresenceObserving {
    /// Live updates for one member until the consumer cancels.
    func observe_member_presence(uid: String) -> AsyncStream<PresenceSnapshot>

    /// Live “who’s online” for a group/room.
    func observe_online_members(club_id: String) -> AsyncStream<[PresenceSnapshot]>
}



// 2) Policy for “who counts as online” (no hardcoded 45s in model)
public struct PresencePolicy {
    public let online_ttl_seconds: TimeInterval
    public let grace_seconds: TimeInterval

    public init(online_ttl_seconds: TimeInterval = 45, grace_seconds: TimeInterval = 10) {
        self.online_ttl_seconds = online_ttl_seconds
        self.grace_seconds = grace_seconds
    }

    public func is_online(last_seen: Date?, state: PresenceState, now: Date = Date()) -> Bool {
        guard state != .offline, let t = last_seen else { return false }
        return now.timeIntervalSince(t) <= (online_ttl_seconds + grace_seconds)
    }
}

public struct PresenceObserver: PresenceObserving {
    private let repository: PresenceRepository
    public init(repository: PresenceRepository) { self.repository = repository }

    public func observe_member_presence(uid: String) -> AsyncStream<PresenceSnapshot> { fatalError() }
    public func observe_online_members(club_id: String) -> AsyncStream<[PresenceSnapshot]> { fatalError() }
}

public protocol PresenceRepository {
    func stream_member(uid: String) -> AsyncStream<PresenceSnapshot>
    func stream_club(club_id: String) -> AsyncStream<[PresenceSnapshot]>
}

