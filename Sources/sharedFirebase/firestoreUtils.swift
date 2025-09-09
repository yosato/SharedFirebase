//
//  File.swift
//  SharedFirebase
//
//  Created by Yo Sato on 2025/09/08.
//

import Foundation
import FirebaseCore
import FirebaseFirestore

public func copy_document_with_subcollections(
    from source: DocumentReference,
    to target: DocumentReference,
    db: Firestore,
    subcollections: [String]
) async throws {
    // copy the document itself
    let snap = try await source.getDocument()
    if snap.exists, let data = snap.data() {
        try await target.setData(data)
    }
    
    // copy named subcollections (one level)
    for name in subcollections {
        let src_col = source.collection(name)
        let dst_col = target.collection(name)
        let qs = try await src_col.getDocuments()
        for d in qs.documents {
            try await dst_col.document(d.documentID).setData(d.data())
        }
    }
}



public func copy_collection_with_subcollections(
    from source_col: CollectionReference,
      to target_col: CollectionReference,
      db: Firestore,
      subcollections: [String]
) async throws {
    let snap = try await source_col.getDocuments()
    for doc in snap.documents {
        try await copy_document_with_subcollections(
            from: source_col.document(doc.documentID),
            to: target_col.document(doc.documentID),
            db: db,
            subcollections: subcollections
        )
    }
}

// MARK: - Helpers

public func wipe_subcollection_page(
    _ subcol: CollectionReference,
    pageSize: Int = 50
) async throws -> Bool {
    let snap = try await subcol.limit(to: pageSize).getDocuments(source: .server)
    guard !snap.documents.isEmpty else { return false }
    let batch = subcol.firestore.batch()
    for d in snap.documents { batch.deleteDocument(d.reference) }
    try await batch.commit()
    return true
}

// Delete ONE document + its NAMED subcollections (one level)
public func delete_document_with_subcollections(
    db: Firestore,
    doc: DocumentReference,
    subcollections: [String],
    pageSize: Int = 50
) async throws {
    // delete subcollections first (paged)
    for name in subcollections {
        let subcol = doc.collection(name)
        while try await wipe_subcollection_page(subcol, pageSize: pageSize) {}
    }
    try await doc.delete()
}

// Delete MANY docs in a collection, incl. their NAMED subcollections (one level)
// ⚠️ Guard the root; and page over parents too.
public func delete_collection_with_subcollections(
    db: Firestore,
    col: CollectionReference,
    subcollections: [String],
    pageSize: Int = 50,
    allowedRootPrefix: String = "fakeClubs" // change to your test root
) async throws {
    precondition(col.path.hasPrefix(allowedRootPrefix),
                 "Refusing to wipe non-test root: \(col.path)")

    while true {
        let snap = try await col.limit(to: pageSize).getDocuments(source: .server)
        if snap.documents.isEmpty { break }
        for doc in snap.documents {
            try await delete_document_with_subcollections(
                db: db,
                doc: doc.reference,
                subcollections: subcollections,
                pageSize: pageSize
            )
        }
    }
}
