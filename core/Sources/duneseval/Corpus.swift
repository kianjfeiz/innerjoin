import Foundation
import AppKit
import PDFKit
import DunesCore

/// A synthetic personal library with known ground truth.
///
/// Twenty-odd documents across the areas an ordinary person accumulates, in the
/// formats they actually arrive in, with entities that recur across them the way real
/// ones do. Because every document's truth is declared here, the pipeline's output can
/// be scored rather than eyeballed.
enum Corpus {

    struct Expected {
        let file: String
        /// What the document is about — the category clustering should discover.
        let area: String
        /// Entities a correct reading would find.
        let entities: [String]
        /// Facts that must survive parsing intact, as (concept, text). The concept is
        /// the canonical field name; a model left to itself will call it something
        /// slightly different on every document, which is the drift being measured.
        let facts: [(concept: String, value: String)]
        /// Names that appear in the text but are scenery, and must not become entities.
        let scenery: [String]
    }

    /// The names a model reaches for when nobody tells it which to use. Every list
    /// means one thing; a library that ends up using all three has three columns where
    /// it should have one.
    static let synonyms: [String: [String]] = [
        "rent_monthly":   ["rent_monthly", "monthly_rent", "rent_amount"],
        "term_end":       ["term_end", "lease_end_date", "end_of_term"],
        "deposit":        ["deposit", "security_deposit", "deposit_amount"],
        "total_due":      ["total_due", "amount_due", "invoice_total"],
        "invoice_date":   ["invoice_date", "date_of_invoice", "issued_on"],
        "deductible":     ["deductible", "annual_deductible", "deductible_amount"],
        "expires":        ["expires", "expiry_date", "coverage_end"],
        "balance":        ["balance", "patient_balance", "amount_outstanding"],
        "statement_date": ["statement_date", "date_of_statement", "period_end"],
        "fare":           ["fare", "ticket_price", "total_paid"],
        "departure":      ["departure", "departure_date", "travel_date"],
        "plate":          ["plate", "plate_number", "registration_number"],
        "fee":            ["fee", "fee_paid", "registration_fee"],
        "closing":        ["closing", "closing_balance", "ending_balance"],
        "ends":           ["ends", "termination_date", "contract_end"],
        "note":           ["note", "detail", "content"],
    ]

    /// Maps any variant back to what it means, so consistency can be scored.
    static let conceptOf: [String: String] = {
        var map: [String: String] = [:]
        for (concept, variants) in synonyms {
            for variant in variants { map[variant] = concept }
        }
        return map
    }()

    static func build(in folder: URL) throws -> [Expected] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var expected: [Expected] = []

        // ---- Apartment: a lease, an amendment by email, a renewal, utilities ----
        expected.append(try lease(folder))
        expected.append(try amendmentEmail(folder))
        expected.append(try renewal(folder))
        expected.append(try utilityBill(folder, month: "July", amount: "97.12"))
        expected.append(try utilityBill(folder, month: "August", amount: "104.38"))

        // ---- Supplies: repeat invoices from one vendor, one scanned ----
        expected.append(try invoice(folder, number: "A-2231", date: "2026-03-14", total: "390.00", scanned: false))
        expected.append(try invoice(folder, number: "A-2198", date: "2026-02-02", total: "212.50", scanned: false))
        expected.append(try invoice(folder, number: "A-2144", date: "2026-01-09", total: "845.00", scanned: true))
        expected.append(try ledger(folder))

        // ---- Health: a policy, a statement, a card photo ----
        expected.append(try policy(folder))
        expected.append(try clinicStatement(folder))
        expected.append(try insuranceCard(folder))

        // ---- Travel: a booking, an itinerary deck ----
        expected.append(try booking(folder))
        expected.append(try itinerary(folder))

        // ---- Odds and ends that shouldn't cluster ----
        expected.append(try shoppingList(folder))
        expected.append(try recipe(folder))

        // ---- Shapes that break naive parsers ----
        expected.append(try formStyle(folder))
        expected.append(try bankStatement(folder))
        expected.append(try longContract(folder))
        expected.append(try germanNotice(folder))
        expected.append(try spreadsheet(folder))
        expected.append(try deck(folder))

        // ---- Traps aimed at a real model rather than at the parser ----
        // Each of these exists because a rule in the prompt is unverifiable without it:
        // a simulator obeys instructions by construction, so "copy values as they
        // appear" and "don't name scenery" can only be tested against a model that has
        // the option of doing otherwise.
        expected.append(try inconsistentInvoice(folder))
        expected.append(try crowdedDeed(folder))
        expected.append(try threeDatedNotice(folder))
        return expected
    }

    // MARK: - Traps for a real model

    /// An invoice whose stated total doesn't equal its own subtotal plus tax.
    ///
    /// Real paperwork contains arithmetic that doesn't add up — a discount applied
    /// off-sheet, a rounding rule, a typo. A model that helpfully "corrects" the total
    /// has silently replaced what the document says with what it thinks, and the
    /// citation then points at a figure that isn't there. The right behaviour is to copy
    /// the printed total, wrong-looking or not.
    private static func inconsistentInvoice(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("invoice_A-2402.pdf"), lines: [
            ("Alcon Laboratories", 16, true), ("", 6, false),
            ("INVOICE A-2402", 13, true),
            ("Date of invoice: 2026-05-19", 11, false),
            ("Bill to: Vahid Feiz", 11, false), ("", 8, false),
            ("Item                       Qty      Each      Amount", 11, true),
            ("Lens cleaner                 6     18.00     108.00", 11, false),
            ("Trial frames                 2     96.00     192.00", 11, false), ("", 6, false),
            ("Subtotal                                     300.00", 11, false),
            ("Tax (8.75%)                                   26.25", 11, false),
            ("Total due                                    311.25", 11, true), ("", 8, false),
            ("Terms: net 30. Remit to Alcon Laboratories.", 11, false),
        ], scanned: false)
        // 300.00 + 26.25 is 326.25. The invoice says 311.25 and 311.25 is the answer.
        return Expected(file: "invoice_A-2402.pdf", area: "Supplies",
                        entities: ["Alcon Laboratories"],
                        facts: [("total_due", "311.25"), ("invoice_date", "2026-05-19")],
                        scenery: [])
    }

    /// A deed thick with names that are not what it's about.
    ///
    /// The entity gate is deterministic and already tested, but it can only refuse what
    /// it's given. This measures what a real model *proposes*: two genuine parties among
    /// a notary, a witness, a recording clerk, a title company in the footer, and a
    /// county. A model that returns all seven is describing the stationery.
    private static func crowdedDeed(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("garage_deed.pdf"), lines: [
            ("QUITCLAIM DEED", 18, true), ("", 8, false),
            ("Grantor: M. Osei. Grantee: Vahid Feiz.", 11, false),
            ("Property: garage space 12, 1247 Fillmore St, San Francisco.", 11, false),
            ("Consideration: $1.00 and other valuable consideration.", 11, false),
            ("Dated 2026-04-02.", 11, false), ("", 8, false),
            ("Witnessed by R. Delacroix. Sworn before notary J. Whitfield,", 11, false),
            ("commission expiring 2028-01-31, County of San Francisco.", 11, false),
            ("Recorded by clerk A. Nakamura, instrument 2026-041882.", 11, false),
            ("Title work by Golden Gate Title Company, order 88-2210.", 9, false),
        ], scanned: false)
        return Expected(file: "garage_deed.pdf", area: "Apartment",
                        entities: ["M. Osei"],
                        facts: [("note", "garage space 12")],
                        // Every one of these is a real name and none is what the deed
                        // is about.
                        scenery: ["J. Whitfield", "R. Delacroix", "A. Nakamura",
                                  "Golden Gate Title Company", "County of San Francisco"])
    }

    /// A notice carrying three dates, only one of which is what it's about.
    ///
    /// Printed date, effective date, respond-by date. `happenedOn` has to be the one the
    /// document is *about*, and the deadline has to land in the dates table so it can
    /// surface in a briefing. Getting this wrong is how an app tells someone the wrong
    /// day.
    private static func threeDatedNotice(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("rent_increase_notice.pdf"), lines: [
            ("NOTICE OF RENT ADJUSTMENT", 17, true), ("", 8, false),
            ("Printed 2026-05-02 by the office of M. Osei.", 10, false), ("", 6, false),
            ("To the tenant of 1247 Fillmore St, Apt 4:", 11, false),
            ("Effective 2026-07-01 the monthly rent becomes $3,395.00,", 11, false),
            ("an increase of $195.00 from the current $3,200.00.", 11, false), ("", 6, false),
            ("If you object you must respond in writing by 2026-06-01.", 11, false),
            ("This notice is given under a thirty (30) day requirement.", 11, false),
        ], scanned: false)
        return Expected(file: "rent_increase_notice.pdf", area: "Apartment",
                        entities: ["M. Osei", "1247 Fillmore St"],
                        facts: [("rent_monthly", "$3,395.00")],
                        scenery: [])
    }

    // MARK: - Questions with known answers

    /// What someone would actually ask, and what a right answer contains.
    ///
    /// Extraction accuracy is only half of it. A library that reads every document
    /// perfectly and then can't answer "when do I have to give notice" hasn't done the
    /// job. These are scored the same way as the facts: the answer must contain the
    /// value, every citation must resolve, and the questions the library *can't* answer
    /// must be refused rather than filled in.
    struct Question {
        let text: String
        /// A string a correct answer must contain. Empty when the point is refusal.
        let expected: String
        /// True when the library genuinely doesn't hold this, and saying so is correct.
        let unanswerable: Bool

        init(_ text: String, expects expected: String) {
            self.text = text; self.expected = expected; self.unanswerable = false
        }
        init(refuses text: String) {
            self.text = text; self.expected = ""; self.unanswerable = true
        }
    }

    static let questions: [Question] = [
        // Straight lookup, one document.
        //
        // Named precisely on purpose. "How much is my monthly rent?" was here first and
        // failed two runs in three — and the system was right to hedge: the library holds
        // a 2024 lease at $3,200, a notice raising it to $3,395 from July 2026, and a
        // renewal. There is no single answer, so scoring one as correct was measuring my
        // own carelessness. The conflict is worth testing, so it gets its own question
        // below rather than being smuggled into this one.
        Question("what monthly rent does the 2024 lease agreement state?", expects: "3,200"),
        Question("what is the security deposit on the lease?", expects: "4,800"),
        Question("when does my lease end?", expects: "2027-03-31"),

        // The figure a model would rather recompute than copy.
        Question("what is the total due on invoice A-2402?", expects: "311.25"),

        // Requires the right date out of three.
        Question("what is the new rent after the increase?", expects: "3,395"),
        Question("by when do I have to object to the rent increase?", expects: "2026-06-01"),

        // The library disagrees with itself, which is the normal case for anything that
        // has ever been amended. Both figures are real and an answer that mentions only
        // one is misleading.
        Question("has the rent changed since the lease was signed?", expects: "3,395"),

        // Named party, not scenery.
        Question("who is my landlord?", expects: "Osei"),

        // Across documents: the policy's own numbers.
        Question("what is my health insurance deductible?", expects: "deductible"),

        // Refusals. The library has none of this, and inventing an answer is the worst
        // possible behaviour — worse than saying nothing.
        Question(refuses: "how much did I pay for my car insurance?"),
        Question(refuses: "what is my passport number?"),
        Question(refuses: "when is my dentist appointment?"),
    ]

    /// Files that must fail, and fail *visibly* rather than vanishing or crashing.
    /// Kept apart from the scored corpus because their success is failure.
    static func buildFailures(in folder: URL) throws -> [String] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("empty.txt"))
        try Data("%PDF-1.4\nthis is not really a pdf".utf8)
            .write(to: folder.appendingPathComponent("truncated.pdf"))
        var broken = ZipWriter()
        broken.add("xl/worksheets/sheet1.xml", "<not-a-worksheet/>")
        try broken.write(to: folder.appendingPathComponent("hollow.xlsx"))
        return ["empty.txt", "truncated.pdf", "hollow.xlsx"]
    }

    // MARK: - Drawing helpers

    private static func font(_ size: CGFloat, _ bold: Bool) -> NSFont {
        NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)!
    }

    /// Renders lines into a PDF. `scanned` bakes the text into an image first, so the
    /// document has no text layer and must go through recognition.
    private static func pdf(_ url: URL, lines: [(String, CGFloat, Bool)], scanned: Bool) throws {
        let size = CGSize(width: 612, height: 792)
        func drawInto(_ ctx: CGContext, scale: CGFloat) {
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            var y: CGFloat = 90
            for (text, points, bold) in lines {
                if text.isEmpty { y += points; continue }
                NSAttributedString(string: text, attributes: [
                    .font: font(points * scale, bold), .foregroundColor: NSColor.black
                ]).draw(at: NSPoint(x: 64 * scale, y: (size.height * scale) - y * scale))
                y += points * 2.0
            }
            NSGraphicsContext.current = nil
        }

        if scanned {
            let scale: CGFloat = 2
            let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
            drawInto(ctx, scale: scale)
            let document = PDFDocument()
            let image = NSImage(cgImage: ctx.makeImage()!, size: size)
            if let page = PDFPage(image: image) { document.insert(page, at: 0) }
            document.write(to: url)
            return
        }

        var box = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        let ctx = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!

        // Break onto a new page rather than drawing past the bottom edge, where the
        // content would simply disappear and the corpus would be quietly wrong.
        var remaining = lines[...]
        repeat {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            var y: CGFloat = 90
            while let next = remaining.first, y < size.height - 60 {
                remaining = remaining.dropFirst()
                if next.0.isEmpty { y += next.1; continue }
                NSAttributedString(string: next.0, attributes: [
                    .font: font(next.1, next.2), .foregroundColor: NSColor.black
                ]).draw(at: NSPoint(x: 64, y: size.height - y))
                y += next.1 * 2.0
            }
            NSGraphicsContext.current = nil
            ctx.endPDFPage()
        } while !remaining.isEmpty
        ctx.closePDF()
        data.write(to: url, atomically: true)
    }

    private static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Apartment

    private static func lease(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("lease_2024.pdf"), lines: [
            ("RESIDENTIAL LEASE AGREEMENT", 20, true), ("", 8, false),
            ("1. Parties", 14, true),
            ("Landlord M. Osei and Tenant Vahid Feiz agree as follows.", 11, false), ("", 8, false),
            ("2. Premises", 14, true),
            ("1247 Fillmore St, Apt 4, San Francisco, CA 94115.", 11, false), ("", 8, false),
            ("3. Rent", 14, true),
            ("Tenant shall pay $3,200.00 per month on the first of each month.", 11, false),
            ("A security deposit of $4,800.00 is held by Landlord.", 11, false), ("", 8, false),
            ("4. Term", 14, true),
            ("The term begins 2024-04-01 and ends 2027-03-31.", 11, false), ("", 8, false),
            ("14. Early Termination", 14, true),
            ("Tenant may terminate on payment of two months rent with sixty (60)", 11, false),
            ("days written notice. Signed 2024-03-14 before notary J. Whitfield.", 11, false),
        ], scanned: false)
        return Expected(file: "lease_2024.pdf", area: "Apartment",
                        entities: ["M. Osei", "1247 Fillmore St"],
                        facts: [("rent_monthly", "$3,200.00"), ("term_end", "2027-03-31"), ("deposit", "$4,800.00")],
                        scenery: ["Tenant", "Landlord", "San Francisco", "CA"])
    }

    private static func amendmentEmail(_ folder: URL) throws -> Expected {
        try write("""
        From: M. Osei <m.osei@example.com>
        To: Vahid Feiz <vafeiz@example.com>
        Subject: Re: lease amendment
        Date: Thu, 12 Mar 2026 16:41:00 -0700
        Content-Type: text/plain; charset=utf-8

        Confirming the change to the lease at 1247 Fillmore St: the early termination
        penalty is reduced to one month's rent, still with 60 days notice.

        M. Osei
        """, to: folder.appendingPathComponent("lease_amendment.eml"))
        return Expected(file: "lease_amendment.eml", area: "Apartment",
                        entities: ["M. Osei", "1247 Fillmore St"],
                        facts: [("note", "one month's rent"), ("note", "60 days notice")], scenery: [])
    }

    private static func renewal(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("lease_renewal_2026.pdf"), lines: [
            ("LEASE RENEWAL", 20, true), ("", 8, false),
            ("This renewal between M. Osei and Vahid Feiz extends the lease", 11, false),
            ("at 1247 Fillmore St through 2027-03-31 at $3,200.00 per month.", 11, false),
            ("The amended termination penalty of one month's rent stands.", 11, false),
            ("Signed 2026-02-28.", 11, false),
        ], scanned: false)
        return Expected(file: "lease_renewal_2026.pdf", area: "Apartment",
                        entities: ["M. Osei", "1247 Fillmore St"],
                        facts: [("rent_monthly", "$3,200.00"), ("term_end", "2027-03-31")], scenery: [])
    }

    private static func utilityBill(_ folder: URL, month: String, amount: String) throws -> Expected {
        let name = "pge_\(month.lowercased()).pdf"
        try pdf(folder.appendingPathComponent(name), lines: [
            ("PACIFIC GAS AND ELECTRIC", 18, true), ("", 6, false),
            ("Service address 1247 Fillmore St, Apt 4.", 11, false),
            ("\(month) statement. Amount due $\(amount).", 11, false),
            ("Account 4419-22. Payable to Pacific Gas and Electric.", 11, false),
        ], scanned: false)
        return Expected(file: name, area: "Apartment",
                        entities: ["Pacific Gas and Electric", "1247 Fillmore St"],
                        facts: [("total_due", "$\(amount)")], scenery: [])
    }

    // MARK: - Supplies

    private static func invoice(_ folder: URL, number: String, date: String,
                                total: String, scanned: Bool) throws -> Expected {
        let name = "invoice_\(number).pdf"
        try pdf(folder.appendingPathComponent(name), lines: [
            ("ALCON LABORATORIES", 20, true), ("", 6, false),
            ("Invoice \(number)", 14, true),
            ("Billed to Eye Care of East Bay.", 11, false),
            ("Invoice date \(date). Payment due within 30 days.", 11, false), ("", 6, false),
            ("Surgical gloves, lens cleaner, exam table paper.", 11, false),
            ("Total due $\(total).", 13, true),
        ], scanned: scanned)
        return Expected(file: name, area: "Supplies",
                        entities: ["Alcon Laboratories", "Eye Care of East Bay"],
                        facts: scanned ? [] : [("total_due", "$\(total)"), ("invoice_date", date)], scenery: [])
    }

    private static func ledger(_ folder: URL) throws -> Expected {
        try write("""
        date,vendor,amount,note
        2026-03-14,Alcon Laboratories,390.00,supplies
        2026-02-02,Alcon Laboratories,212.50,supplies
        2026-01-09,Alcon Laboratories,845.00,supplies
        2026-03-01,"Pacific Gas and Electric",97.12,utility
        """, to: folder.appendingPathComponent("supplier_ledger.csv"))
        return Expected(file: "supplier_ledger.csv", area: "Supplies",
                        entities: ["Alcon Laboratories"],
                        facts: [("total_due", "390.00"), ("note", "845.00")], scenery: [])
    }

    // MARK: - Health

    private static func policy(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("health_policy_2026.pdf"), lines: [
            ("STATE FARM HEALTH POLICY", 18, true), ("", 6, false),
            ("Policyholder Vahid Feiz. Policy SF-88213.", 11, false),
            ("Coverage year begins 2026-01-01 and expires 2026-12-31.", 11, false),
            ("Individual deductible $1,500.00. Family deductible $3,000.00.", 11, false),
            ("In-network care through Chen Clinic.", 11, false),
        ], scanned: false)
        return Expected(file: "health_policy_2026.pdf", area: "Health",
                        entities: ["State Farm", "Chen Clinic"],
                        facts: [("deductible", "$1,500.00"), ("expires", "2026-12-31")], scenery: ["Policyholder"])
    }

    private static func clinicStatement(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("clinic_statement.pdf"), lines: [
            ("CHEN CLINIC", 18, true), ("", 6, false),
            ("Statement date 2026-05-04 for Vahid Feiz.", 11, false),
            ("Visit copay $45.00. Patient balance $128.50.", 11, false),
            ("Billed to State Farm under policy SF-88213.", 11, false),
        ], scanned: false)
        return Expected(file: "clinic_statement.pdf", area: "Health",
                        entities: ["Chen Clinic", "State Farm"],
                        facts: [("balance", "$128.50"), ("statement_date", "2026-05-04")], scenery: [])
    }

    private static func insuranceCard(_ folder: URL) throws -> Expected {
        let url = folder.appendingPathComponent("insurance_card.png")
        let width = 900, height = 520
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        func line(_ text: String, _ y: CGFloat, _ size: CGFloat, _ bold: Bool = false) {
            NSAttributedString(string: text, attributes: [
                .font: font(size, bold), .foregroundColor: NSColor.black
            ]).draw(at: NSPoint(x: 60, y: CGFloat(height) - y))
        }
        line("STATE FARM", 90, 34, true)
        line("Member Vahid Feiz", 160, 22)
        line("Policy SF-88213", 205, 22)
        line("Group 4471", 250, 22)
        line("Care network: Chen Clinic", 300, 20)
        NSGraphicsContext.current = nil
        let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return Expected(file: "insurance_card.png", area: "Health",
                        entities: ["State Farm", "Chen Clinic"], facts: [], scenery: [])
    }

    // MARK: - Travel

    private static func booking(_ folder: URL) throws -> Expected {
        try write("""
        From: Skyline Air <noreply@skylineair.example>
        To: Vahid Feiz <vafeiz@example.com>
        Subject: Your booking SKY-7741
        Date: Mon, 06 Apr 2026 09:12:00 -0700
        Content-Type: text/plain; charset=utf-8

        Booking SKY-7741 confirmed with Skyline Air.
        Departing 2026-10-03 from San Francisco to New York.
        Total paid $412.60. Hotel booked separately with Harbourview Inn.
        """, to: folder.appendingPathComponent("flight_booking.eml"))
        return Expected(file: "flight_booking.eml", area: "Travel",
                        entities: ["Skyline Air", "Harbourview Inn"],
                        facts: [("fare", "$412.60"), ("departure", "2026-10-03")],
                        scenery: ["San Francisco", "New York"])
    }

    private static func itinerary(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("trip_itinerary.pdf"), lines: [
            ("OCTOBER TRIP", 20, true), ("", 6, false),
            ("Skyline Air SKY-7741 departs 2026-10-03.", 11, false),
            ("Harbourview Inn, three nights, $624.00 total.", 11, false),
            ("Return 2026-10-07.", 11, false),
        ], scanned: false)
        return Expected(file: "trip_itinerary.pdf", area: "Travel",
                        entities: ["Skyline Air", "Harbourview Inn"],
                        facts: [("fare", "$624.00"), ("departure", "2026-10-07")], scenery: [])
    }

    // MARK: - Unrelated

    private static func shoppingList(_ folder: URL) throws -> Expected {
        try write("""
        # Shopping

        - oat milk
        - coffee beans
        - dish soap
        """, to: folder.appendingPathComponent("shopping.md"))
        return Expected(file: "shopping.md", area: "Everything else",
                        entities: [], facts: [("note", "coffee beans")], scenery: [])
    }

    // MARK: - Awkward shapes

    /// Label-and-value pairs in columns. Read naively the labels and values interleave
    /// and every value ends up attached to the wrong field.
    private static func formStyle(_ folder: URL) throws -> Expected {
        try pdf(folder.appendingPathComponent("registration_form.pdf"), lines: [
            ("VEHICLE REGISTRATION", 18, true), ("", 8, false),
            ("Owner                    Vahid Feiz", 11, false),
            ("Plate                    7XKD449", 11, false),
            ("Expires                  2027-08-31", 11, false),
            ("Fee paid                 $214.00", 11, false),
            ("Insurer                  State Farm", 11, false),
        ], scanned: false)
        return Expected(file: "registration_form.pdf", area: "Everything else",
                        entities: ["State Farm"],
                        facts: [("plate", "7XKD449"), ("expires", "2027-08-31"), ("fee", "$214.00")], scenery: ["Owner"])
    }

    /// Many rows of numbers — the shape most likely to be flattened into a soup of
    /// digits, and the one where that damage is hardest to spot afterwards.
    private static func bankStatement(_ folder: URL) throws -> Expected {
        var lines: [(String, CGFloat, Bool)] = [
            ("FIRST HARBOUR BANK", 18, true), ("", 6, false),
            ("Statement period 2026-06-01 to 2026-06-30.", 11, false), ("", 6, false),
            ("Date          Description                  Amount", 11, true),
        ]
        let rows = [("2026-06-02", "Alcon Laboratories", "-390.00"),
                    ("2026-06-05", "Pacific Gas and Electric", "-97.12"),
                    ("2026-06-09", "Chen Clinic", "-45.00"),
                    ("2026-06-15", "Deposit", "+2,400.00"),
                    ("2026-06-28", "M. Osei rent", "-3,200.00")]
        for row in rows {
            lines.append(("\(row.0)    \(row.1.padding(toLength: 28, withPad: " ", startingAt: 0))\(row.2)", 11, false))
        }
        lines.append(("", 6, false))
        lines.append(("Closing balance $1,284.55.", 12, true))
        try pdf(folder.appendingPathComponent("bank_statement_june.pdf"), lines: lines, scanned: false)
        return Expected(file: "bank_statement_june.pdf", area: "Everything else",
                        entities: ["First Harbour Bank"],
                        facts: [("closing", "$1,284.55"), ("statement_date", "2026-06-30")], scenery: ["Deposit"])
    }

    /// Long enough to span pages, so pagination and the token budget both get exercised.
    private static func longContract(_ folder: URL) throws -> Expected {
        var lines: [(String, CGFloat, Bool)] = [("SERVICE AGREEMENT", 20, true), ("", 8, false)]
        for section in 1...26 {
            lines.append(("\(section). Clause \(section)", 13, true))
            lines.append(("Eye Care of East Bay engages Alcon Laboratories for supply of", 11, false))
            lines.append(("consumables under the terms set out in this section.", 11, false))
            lines.append(("", 6, false))
        }
        lines.append(("This agreement terminates 2028-01-31 unless renewed.", 11, false))
        try pdf(folder.appendingPathComponent("service_agreement.pdf"), lines: lines, scanned: false)
        return Expected(file: "service_agreement.pdf", area: "Supplies",
                        entities: ["Alcon Laboratories", "Eye Care of East Bay"],
                        facts: [("ends", "2028-01-31")], scenery: [])
    }

    /// Not English. Accented characters must survive normalization, and the language
    /// must not stop the document being read at all.
    private static func germanNotice(_ folder: URL) throws -> Expected {
        try write("""
        # Mietanpassung

        Sehr geehrter Herr Feiz,

        die monatliche Miete für 1247 Fillmore St beträgt ab 2027-04-01
        3.400,00 EUR. Änderungen bestätigt durch M. Osei.
        """, to: folder.appendingPathComponent("mietanpassung.md"))
        return Expected(file: "mietanpassung.md", area: "Apartment",
                        entities: ["M. Osei", "1247 Fillmore St"],
                        facts: [("rent_monthly", "3.400,00 EUR"), ("term_end", "2027-04-01")], scenery: [])
    }

    private static func spreadsheet(_ folder: URL) throws -> Expected {
        let strings = ["Vendor", "Spend", "Alcon Laboratories", "Chen Clinic", "Skyline Air"]
        let shared = #"<?xml version="1.0"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
            + strings.map { "<si><t>\($0)</t></si>" }.joined() + "</sst>"
        let rows = """
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>1447.50</v></c></row>
        <row r="3"><c r="A3" t="s"><v>3</v></c><c r="B3"><v>173.50</v></c></row>
        <row r="4"><c r="A4" t="s"><v>4</v></c><c r="B4"><v>412.60</v></c></row>
        """
        var archive = ZipWriter()
        archive.add("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        archive.add("xl/sharedStrings.xml", shared)
        archive.add("xl/worksheets/sheet1.xml",
                    #"<?xml version="1.0"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
                    + rows + "</sheetData></worksheet>")
        try archive.write(to: folder.appendingPathComponent("annual_spend.xlsx"))
        return Expected(file: "annual_spend.xlsx", area: "Supplies",
                        entities: ["Alcon Laboratories"],
                        facts: [("total_due", "1447.50"), ("note", "Chen Clinic")], scenery: [])
    }

    private static func deck(_ folder: URL) throws -> Expected {
        func slide(_ title: String, _ bullets: [String]) -> String {
            let paragraphs = ([title] + bullets)
                .map { "<a:p><a:r><a:t>\($0)</a:t></a:r></a:p>" }.joined()
            return #"<?xml version="1.0"?><p:sld xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><p:cSld><p:spTree><p:sp><p:txBody>"#
                + paragraphs + "</p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
        }
        var archive = ZipWriter()
        archive.add("[Content_Types].xml", #"<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>"#)
        archive.add("ppt/slides/slide1.xml", slide("Supplier review", ["Prepared for Eye Care of East Bay"]))
        archive.add("ppt/slides/slide2.xml", slide("Spend", ["Alcon Laboratories $1,447.50"]))
        try archive.write(to: folder.appendingPathComponent("supplier_review.pptx"))
        return Expected(file: "supplier_review.pptx", area: "Supplies",
                        entities: ["Alcon Laboratories", "Eye Care of East Bay"],
                        facts: [("total_due", "$1,447.50")], scenery: [])
    }

    private static func recipe(_ folder: URL) throws -> Expected {
        try write("""
        # Braised beans

        Soak overnight. Cook low for three hours with garlic and bay.
        Finish with olive oil and lemon.
        """, to: folder.appendingPathComponent("recipe.md"))
        return Expected(file: "recipe.md", area: "Everything else",
                        entities: [], facts: [("note", "three hours")], scenery: [])
    }
}
