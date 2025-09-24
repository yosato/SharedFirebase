//
//  Presence.swift
//  SharedFirebase
//
//  Created by Yo Sato on 2025/09/22.
//

import Foundation
import FirebaseFirestore

// MARK: - Models & Policy

public protocol MemberRepresentable {
    var uid: String { get }
    var displayName: String { get }
}

public enum PresenceState: String, Codable, Equatable {
    case online
    case background
    case offline
    case unknown
}

public struct PresenceSnapshot: Equatable {
    public let uid: String
    public let state: PresenceState
    public let lastSeen: Date?

    public init(uid: String, state: PresenceState, lastSeen: Date?) {
        self.uid = uid
        self.state = state
        self.lastSeen = lastSeen
    }

    public func is_online(_ policy: PresencePolicy = PresencePolicy()) -> Bool {
        policy.is_online(lastSeen: lastSeen, state: state)
    }
}

public struct PresencePolicy {
    public let onlineTtlSeconds: TimeInterval
    public let graceSeconds: TimeInterval

    public init(onlineTtlSeconds: TimeInterval = 45, graceSeconds: TimeInterval = 10) {
        self.onlineTtlSeconds = onlineTtlSeconds
        self.graceSeconds = graceSeconds
    }

    public func is_online(lastSeen: Date?, state: PresenceState, now: Date = Date()) -> Bool {
        guard state != .offline, let t = lastSeen else { return false }
        return now.timeIntervalSince(t) <= (onlineTtlSeconds + graceSeconds)
    }
}

// MARK: - Protocols (one-shot only)

public protocol PresenceManaging {
    func start_tracking(uid: String, deviceID: String?, appVersion: String?) async
    func stop_tracking(uid: String) async
    func mark_background(uid: String) async
    func mark_foreground(uid: String) async
}

public protocol PresenceObserving {
    func get_member_presence(uid: String) async -> PresenceSnapshot?
    func get_online_users(policy: PresencePolicy) async -> [PresenceSnapshot]
}

public protocol PresenceStore {
    // reads
    func fetch_member(uid: String) async -> PresenceSnapshot?
    func fetch_online_users(policy: PresencePolicy) async -> [PresenceSnapshot]

    // writes
    func set_presence(uid: String,
                      state: PresenceState,
                      lastSeen: Date,
                      deviceID: String?,
                      appVersion: String?) async throws

    func clear_presence(uid: String) async throws
}

// MARK: - Observer (pass-through)

public struct PresenceObserver: PresenceObserving {
    private let repository: PresenceStore
    public init(repository: PresenceStore) { self.repository = repository }

    public func get_member_presence(uid: String) async -> PresenceSnapshot? {
        await repository.fetch_member(uid: uid)
    }

    public func get_online_users(policy: PresencePolicy) async -> [PresenceSnapshot] {
        await repository.fetch_online_users(policy: policy)
    }
}

// MARK: - Firestore Store

public final class FirestorePresenceStore: PresenceStore {
    private let db: Firestore
    private let presenceCol: CollectionReference

    public init(db: Firestore = Firestore.firestore(), collectionPath: String = "onlineUsers") {
        self.db = db
        self.presenceCol = db.collection(collectionPath)
    }

    private func doc_ref(uid: String) -> DocumentReference {
        presenceCol.document(uid)
    }

    // MARK: Reads

    public func fetch_member(uid: String) async -> PresenceSnapshot? {
        do {
            let snap = try await doc_ref(uid: uid).getDocument()
            guard snap.exists, let data = snap.data() else { return nil }
            return decode_snapshot(uid: uid, data: data)
        } catch {
            return nil
        }
    }

    public func fetch_online_users(policy: PresencePolicy) async -> [PresenceSnapshot] {
        let cutoff = Date(timeIntervalSinceNow: -(policy.onlineTtlSeconds + policy.graceSeconds))
        let cutoffTS = Timestamp(date: cutoff)
        do {
            let q = presenceCol
                .whereField("state", in: ["online", "background"])
                .whereField("lastSeen", isGreaterThanOrEqualTo: cutoffTS)
            let snap = try await q.getDocuments()
            return snap.documents.compactMap { doc in
                decode_snapshot(uid: doc.documentID, data: doc.data())
            }.filter { $0.is_online(policy) }
        } catch {
            return []
        }
    }

    // MARK: Writes

    public func set_presence(uid: String,
                             state: PresenceState,
                             lastSeen: Date,
                             deviceID: String?,
                             appVersion: String?) async throws {
        var payload: [String: Any] = [
            "uid": uid,
            "state": state.rawValue,
            "lastSeen": Timestamp(date: lastSeen),
        ]
        if let deviceID { payload["deviceID"] = deviceID }
        if let appVersion { payload["appVersion"] = appVersion }

        try await doc_ref(uid: uid).setData(payload, merge: true)
    }

    public func clear_presence(uid: String) async throws {
        try await doc_ref(uid: uid).setData([
            "uid": uid,
            "state": PresenceState.offline.rawValue,
            "lastSeen": Timestamp(date: Date())
        ], merge: true)
    }

    // MARK: Helpers

    private func decode_snapshot(uid: String, data: [String: Any]) -> PresenceSnapshot {
        let stateRaw = data["state"] as? String ?? PresenceState.unknown.rawValue
        let state = PresenceState(rawValue: stateRaw) ?? .unknown
        let ts = data["lastSeen"] as? Timestamp
        return PresenceSnapshot(uid: uid, state: state, lastSeen: ts?.dateValue())
    }
}

// MARK: - Manager

public final class FirestorePresenceManager: PresenceManaging {
    private let store: PresenceStore
    private let clock: () -> Date

    public init(store: PresenceStore, clock: @escaping () -> Date = { Date() }) {
        self.store = store
        self.clock = clock
    }

    public func start_tracking(uid: String, deviceID: String?, appVersion: String?) async {
        do {
            try await store.set_presence(uid: uid,
                                         state: .online,
                                         lastSeen: clock(),
                                         deviceID: deviceID,
                                         appVersion: appVersion)
        } catch {}
    }

    public func stop_tracking(uid: String) async {
        do {
            try await store.clear_presence(uid: uid)
        } catch {}
    }

    public func mark_background(uid: String) async {
        do {
            try await store.set_presence(uid: uid,
                                         state: .background,
                                         lastSeen: clock(),
                                         deviceID: nil,
                                         appVersion: nil)
        } catch {}
    }

    public func mark_foreground(uid: String) async {
        do {
            try await store.set_presence(uid: uid,
                                         state: .online,
                                         lastSeen: clock(),
                                         deviceID: nil,
                                         appVersion: nil)
        } catch {}
    }
}

