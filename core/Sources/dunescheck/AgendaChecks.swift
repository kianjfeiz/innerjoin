import Foundation
import GRDB
import DunesCore

/// The agenda turns a library into a list of things waiting on a person. Three
/// properties matter more than the rest, and none of them are visible by looking at
/// the screen once:
///
///   1. Finishing something has to survive the document being understood again.
///   2. Dates that record the past must not appear as work.
///   3. What slipped must sort above what is merely coming.
func agendaChecks() async {
    await check("dates that record the past are not work", recordKeepingExcluded)
    await check("a document's own words map onto the kinds", kindMapping)
    await check("what slipped sorts above what's coming", overdueLeads)
    await check("finishing something hides it", finishingHides)
    await check("finishing survives the document being re-read", finishingSurvivesReread)
    await check("keys don't move between launches", keysAreStable)
    await check("a snooze hides until its date, then stops", snoozeExpires)
    await check("contradictions become things to check", anomaliesBecomeChecks)
    await check("pruning keeps what a person finished", pruningKeepsDone)
}

// MARK: - Seeding

/// A document with a record and whatever dates a check needs. Written straight to the
/// store because the pipeline that normally produces this needs a model, and none of
/// these properties are about the model.
@discardableResult
private func seed(_ store: Store, name: String, title: String,
                  dates: [(kind: String, date: Date)]) throws -> Int64 {
    try store.dbQueue.write { db in
        var document = Document(
            vaultPath: "xx/\(name)", name: name,
            sha256: Agenda.stableHash(name) + String(repeating: "0", count: 8),
            typeIdentifier: "public.plain-text", byteSize: 10,
            stage: .understood)
        try document.insert(db)
        let documentID = document.id!
        var record = DunesCore.Record(documentID: documentID, title: title)
        try record.insert(db)
        for entry in dates {
            var date = RecordDate(recordID: record.id!, kind: entry.kind, date: entry.date)
            try date.insert(db)
        }
        return documentID
    }
}

/// Re-understanding a document: the record and its dates are thrown away and written
/// again, with new row ids. Exactly what must not disturb a person's decisions.
private func reread(_ store: Store, documentID: Int64,
                    dates: [(kind: String, date: Date)]) throws {
    try store.dbQueue.write { db in
        try DunesCore.Record.filter(Column("documentID") == documentID).deleteAll(db)
        var record = DunesCore.Record(documentID: documentID, title: "Northgate lease")
        try record.insert(db)
        for entry in dates {
            var date = RecordDate(recordID: record.id!, kind: entry.kind, date: entry.date)
            try date.insert(db)
        }
    }
}

private func day(_ offset: Int, from now: Date = Date()) -> Date {
    Calendar.current.date(byAdding: .day, value: offset, to: now)!
}

// MARK: - Checks

private func recordKeepingExcluded() async throws {
    try await withWorkspace { store in
        try seed(store, name: "lease.md", title: "Northgate lease", dates: [
            ("signed", day(-30)), ("issued", day(-29)), ("paid", day(-5)),
            ("term_end", day(40)),
        ])
        let items = try Agenda().items(store: store)
        await expectEqual(items.count, 1, "only the term end is work")
        await expectEqual(items.first?.kind, .deadline, "a term end is a deadline")
    }
}

private func kindMapping() async throws {
    // The model is asked for the document's vocabulary, so the mapping has to cope
    // with words nobody enumerated.
    await expectEqual(Commitment.Kind.of(dateKind: "kickoff_call"), .meeting, "a call is a meeting")
    await expectEqual(Commitment.Kind.of(dateKind: "Interview"), .meeting, "an interview is a meeting")
    await expectEqual(Commitment.Kind.of(dateKind: "payment_due"), .payment, "payment due is money")
    await expectEqual(Commitment.Kind.of(dateKind: "invoice_due"), .payment, "an invoice is money")
    await expectEqual(Commitment.Kind.of(dateKind: "reply_by"), .reply, "reply_by wants an answer")
    await expectEqual(Commitment.Kind.of(dateKind: "rsvp"), .reply, "an rsvp wants an answer")
    await expectEqual(Commitment.Kind.of(dateKind: "delivery"), .milestone, "a delivery starts something")
    await expectEqual(Commitment.Kind.of(dateKind: "notice_deadline"), .deadline, "a notice is a deadline")
    await expect(Commitment.Kind.isRecordKeeping(dateKind: "signed"), "signed is the past")
    await expect(!Commitment.Kind.isRecordKeeping(dateKind: "due"), "due is not the past")
}

private func overdueLeads() async throws {
    try await withWorkspace { store in
        try seed(store, name: "a.md", title: "Coming up", dates: [("due", day(9))])
        try seed(store, name: "b.md", title: "Slipped", dates: [("due", day(-9))])
        try seed(store, name: "c.md", title: "Today", dates: [("due", day(0))])
        let items = try Agenda().items(store: store)
        await expectEqual(items.map(\.title), ["Slipped", "Today", "Coming up"],
                          "overdue, then today, then later")
        await expectEqual(items.first?.horizon(), .overdue, "the first one reads as overdue")
    }
}

private func finishingHides() async throws {
    try await withWorkspace { store in
        try seed(store, name: "a.md", title: "Renew the policy", dates: [("due", day(6))])
        let before = try Agenda().items(store: store)
        await expectEqual(before.count, 1, "one thing waiting")

        try store.setTaskDone(key: before[0].id, done: true)
        await expectEqual(try Agenda().items(store: store).count, 0, "finishing takes it off the list")

        let settled = try Agenda(includeSettled: true).items(store: store)
        await expectEqual(settled.count, 1, "it still exists when you ask for everything")
        await expect(settled[0].isDone, "and it knows it's done")

        try store.setTaskDone(key: before[0].id, done: false)
        await expectEqual(try Agenda().items(store: store).count, 1, "and it can come back")
    }
}

private func finishingSurvivesReread() async throws {
    try await withWorkspace { store in
        let dates = [(kind: "term_end", date: day(45))]
        let documentID = try seed(store, name: "lease.md", title: "Northgate lease", dates: dates)
        let item = try Agenda().items(store: store)[0]
        try store.setTaskDone(key: item.id, done: true)
        await expectEqual(try Agenda().items(store: store).count, 0, "finished")

        // The whole point: new row ids, same decision.
        try reread(store, documentID: documentID, dates: dates)
        let after = try Agenda().items(store: store)
        await expectEqual(after.count, 0, "re-reading the document does not resurrect it")

        let settled = try Agenda(includeSettled: true).items(store: store)
        await expectEqual(settled.first?.id, item.id, "the key is the same one")
    }
}

private func keysAreStable() async throws {
    // Swift's Hasher is seeded per process, so a key built on it would change every
    // launch and silently un-finish everything. This is the guard on that.
    await expectEqual(Agenda.stableHash("Due 2025-04-01 is before the invoice date."),
                      Agenda.stableHash("Due 2025-04-01 is before the invoice date."),
                      "the same text hashes the same way")
    await expect(Agenda.stableHash("a") != Agenda.stableHash("b"), "different text differs")
    // A literal, so a change in the hash function shows up here rather than as a
    // library that forgot what you'd finished.
    await expectEqual(Agenda.stableHash("northgate"), "373mwbia44fxf", "the hash is pinned")
}

private func snoozeExpires() async throws {
    try await withWorkspace { store in
        try seed(store, name: "a.md", title: "Look at this later", dates: [("due", day(3))])
        let item = try Agenda().items(store: store)[0]

        try store.setTaskSnoozed(key: item.id, until: day(2))
        await expectEqual(try Agenda().items(store: store).count, 0, "set aside, so out of the way")
        await expectEqual(try Agenda(includeSettled: true).items(store: store).count, 1,
                          "but not gone")

        // Once the date passes it comes back on its own — a snooze is a delay, not a
        // deletion, and the difference is the whole reason to trust one.
        try store.setTaskSnoozed(key: item.id, until: day(-1))
        await expectEqual(try Agenda().items(store: store).count, 1, "and it returns by itself")
    }
}

private func anomaliesBecomeChecks() async throws {
    try await withWorkspace { store in
        let documentID = try seed(store, name: "invoice.md", title: "Invoice 4417",
                                  dates: [("due", day(5))])
        try await store.dbQueue.write { db in
            var anomaly = Anomaly(documentID: documentID, kind: .dateOrder,
                                  detail: "Due 2025-04-01 is before the invoice date.",
                                  foundBy: .checked, noticedAt: Date())
            try anomaly.insert(db)
        }
        let items = try Agenda().items(store: store)
        await expectEqual(items.count, 2, "the date and the contradiction")
        await expectEqual(items.last?.kind, .check, "a contradiction is something to check")
        await expectNil(items.last?.due, "and it has no date of its own")
        await expectEqual(items.last?.horizon(), .someday, "so it sits under 'No date'")
    }
}

private func pruningKeepsDone() async throws {
    try await withWorkspace { store in
        try seed(store, name: "a.md", title: "Finished thing", dates: [("due", day(4))])
        let item = try Agenda().items(store: store)[0]
        try store.setTaskDone(key: item.id, done: true)
        try store.setTaskSnoozed(key: "d:999:gone:20200101", until: day(30))

        // Pruning is for keys no document produces any more. What a person finished is
        // a record of what they did, and outlives the document that prompted it.
        let live = try Agenda().liveKeys(store: store)
        let removed = try store.forgetTaskStates(keeping: live)
        await expectEqual(removed, 1, "the dead key goes")
        await expect(try store.taskStates()[item.id]?.doneAt != nil, "the finished one stays")
    }
}
