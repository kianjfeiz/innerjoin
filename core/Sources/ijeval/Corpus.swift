import Foundation
import AppKit
import PDFKit
import InnerjoinCore

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
        /// Facts that must survive parsing intact, checked as substrings of the markdown.
        let facts: [String]
        /// Names that appear in the text but are scenery, and must not become entities.
        let scenery: [String]
    }

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
        return expected
    }

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
                        facts: ["$3,200.00", "2027-03-31", "$4,800.00"],
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
                        facts: ["one month's rent", "60 days notice"], scenery: [])
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
                        facts: ["$3,200.00", "2027-03-31"], scenery: [])
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
                        facts: ["$\(amount)"], scenery: [])
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
                        facts: scanned ? [] : ["$\(total)", date], scenery: [])
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
                        facts: ["390.00", "845.00"], scenery: [])
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
                        facts: ["$1,500.00", "2026-12-31"], scenery: ["Policyholder"])
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
                        facts: ["$128.50", "2026-05-04"], scenery: [])
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
                        facts: ["$412.60", "2026-10-03"],
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
                        facts: ["$624.00", "2026-10-07"], scenery: [])
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
                        entities: [], facts: ["coffee beans"], scenery: [])
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
                        facts: ["7XKD449", "2027-08-31", "$214.00"], scenery: ["Owner"])
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
                        facts: ["$1,284.55", "2026-06-30"], scenery: ["Deposit"])
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
                        facts: ["2028-01-31"], scenery: [])
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
                        facts: ["3.400,00 EUR", "2027-04-01"], scenery: [])
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
                        facts: ["1447.50", "Chen Clinic"], scenery: [])
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
                        facts: ["$1,447.50"], scenery: [])
    }

    private static func recipe(_ folder: URL) throws -> Expected {
        try write("""
        # Braised beans

        Soak overnight. Cook low for three hours with garlic and bay.
        Finish with olive oil and lemon.
        """, to: folder.appendingPathComponent("recipe.md"))
        return Expected(file: "recipe.md", area: "Everything else",
                        entities: [], facts: ["three hours"], scenery: [])
    }
}
