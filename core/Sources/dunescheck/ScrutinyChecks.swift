import Foundation
import DunesCore

func scrutinyChecks() async {
    print("\nScrutiny · noticing a document is wrong")
    await check("a claim that disproves itself is dropped", selfRefuting)
    await check("dates in an impossible order are caught by rule", dateOrderByRule)
    await check("the value stays exactly as printed", valuesAreNotCorrected)
    await check("the same observation twice is listed once", deduplicated)
    await check("the finding is classified by what it says, not by its label", classified)
}

private func selfRefuting() async throws {
    // From a real run against a corrupted spreadsheet. Three of four arithmetic findings
    // on that document were of this shape: the sentence asserts a mismatch and then shows
    // the two sides agreeing.
    await expect(Scrutiny.refutesItself(
        "Subtotal 1855.75 does not match sum of line totals (450 + 749.95 + 476 + 179.8 = 1855.75)"),
        "a sum that matches is not a mismatch")
    await expect(Scrutiny.refutesItself(
        "Tax 153.099375 is 8.25% of 1855.75, but 8.25% of 1855.75 = 153.099375"),
        "nor is a percentage that works out")

    // The genuine findings from the same corpus must survive.
    await expect(!Scrutiny.refutesItself(
        "Line total for USB-C Dock (5 x 129.99) is 749.95, but 5 x 129.99 = 649.95"),
        "a real arithmetic error is kept")
    await expect(!Scrutiny.refutesItself(
        "Line item lists 2 x $389.00 as $877.00, but 2 x $389.00 = $778.00"),
        "and so is a transposed total")
    await expect(!Scrutiny.refutesItself("Attendees (4) lists only 3 people"),
                 "a claim with no arithmetic in it is left alone")
}

private func dateOrderByRule() async throws {
    // Rule-checked findings don't depend on the model noticing, which is why they carry
    // `checked` rather than `reported`.
    try await withWorkspace { store in
        let added = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(added.document.id, "id")

        let provider = ScriptedProvider(json: """
        {"title":"Invoice","summary":"s","fields":[],"entities":[],"assertions":[],"problems":[],
         "dates":[{"kind":"invoice_date","date":"2025-04-15"},
                  {"kind":"due_date","date":"2025-04-05"}]}
        """)
        _ = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        let anomalies = try store.anomalies(of: documentID)
        let ordering = anomalies.filter { $0.kind == .dateOrder }
        await expectEqual(ordering.count, 1, "the impossible order is caught")
        await expectEqual(ordering.first?.foundBy, .checked, "by rule, not by the model noticing")
        await expect(ordering.first?.detail.contains("2025-04-05") == true,
                     "and the finding names the offending date")
    }
}

private func valuesAreNotCorrected() async throws {
    // The whole discipline. A flagged document keeps the number that is printed on it,
    // because the value and the page it cites have to agree — the moment dunes
    // silently fixes a figure, every citation stops meaning what it appears to mean.
    try await withWorkspace { store in
        let added = try await Ingest(store: store).add(fileAt: try fixture("lease.pdf"))
        let documentID = try require(added.document.id, "id")

        let provider = ScriptedProvider(json: """
        {"title":"Invoice","summary":"s","dates":[],"entities":[],"assertions":[],
         "fields":[{"name":"line_total","value":"$877.00","source":"e0"}],
         "problems":[{"kind":"arithmetic","detail":"2 x $389.00 is listed as $877.00, but equals $778.00","source":"e0"}]}
        """)
        _ = try await Distill(store: store, provider: provider).understand(documentID: documentID)

        let record = try require(try store.record(ofDocument: documentID), "the record")
        await expectEqual(record.fields["line_total"]?.value, "$877.00",
                          "the stored value is what the document printed, wrong or not")
        await expectEqual(try store.anomalies(of: documentID).count, 1,
                          "with the objection recorded beside it")
    }
}

private func deduplicated() async throws {
    await expectEqual(Scrutiny.signature("Order ID ORD-2001 appears twice in the sheet"),
                      Scrutiny.signature("The sheet contains ORD-2001 twice, appears duplicated"),
                      "wording differs, the observation doesn't")
    await expect(Scrutiny.signature("Total does not match the lines")
                 != Scrutiny.signature("Due date precedes the invoice date"),
                 "genuinely different observations stay apart")
}


private func classified() async throws {
    // Every one of these came back from a real run under the wrong label. The kind is
    // what a UI groups and filters on, so a misfiled finding is a finding nobody sees.
    await expectEqual(Scrutiny.classify("Order date is stated as 'Febuary 11, 2025' — a misspelling of February"),
                      .typo, "a misspelling is a typo, not a date-order problem")
    await expectEqual(Scrutiny.classify("Region values vary in casing: 'west' is lowercase while others use 'West'"),
                      .inconsistentFormat, "casing is a format inconsistency, not a count mismatch")
    await expectEqual(Scrutiny.classify("2025-06-31 does not exist; June has 30 days"),
                      .impossibleDate, "an impossible date is read as one")
    await expectEqual(Scrutiny.classify("Product id P-100 appears twice with different prices"),
                      .duplicate, "and a duplicate as one")
    await expectEqual(Scrutiny.classify("The RSVP deadline is July 20, after the event on July 19"),
                      .dateOrder, "ordering is still ordering")
    await expect(Scrutiny.classify("Something entirely unremarkable") == nil,
                 "and an unclassifiable sentence falls back to the label")
}
