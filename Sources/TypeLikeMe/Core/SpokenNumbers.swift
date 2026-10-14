import Foundation

/// Writes spoken numbers the way people type them, conservatively:
/// "fifty percent" → 50%, "twenty k" → 20k, "two thousand five hundred" → 2,500, "two point five" → 2.5,
/// "three thirty pm" → 3:30 PM, "October twenty first twenty twenty five" → October 21, 2025,
/// "nine eight seven six five" → 98765. Small counts stay words ("one more thing", "in a second", "two days").
/// Anything ambiguous ("twenty four seven", "fifty fifty") is left exactly as said.
enum SpokenNumbers {
    private static let units: [String: Int] = ["zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    private static let teens: [String: Int] = ["ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
                                               "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19]
    private static let tens: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90]
    private static let scales: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]
    /// Ordinal word → its cardinal word.
    private static let ordinals: [String: String] = [
        "first": "one", "second": "two", "third": "three", "fourth": "four", "fifth": "five", "sixth": "six", "seventh": "seven",
        "eighth": "eight", "ninth": "nine", "tenth": "ten", "eleventh": "eleven", "twelfth": "twelve", "thirteenth": "thirteen",
        "fourteenth": "fourteen", "fifteenth": "fifteen", "sixteenth": "sixteen", "seventeenth": "seventeen", "eighteenth": "eighteen",
        "nineteenth": "nineteen", "twentieth": "twenty", "thirtieth": "thirty", "fortieth": "forty", "fiftieth": "fifty",
        "sixtieth": "sixty", "seventieth": "seventy", "eightieth": "eighty", "ninetieth": "ninety", "hundredth": "hundred",
        "thousandth": "thousand",
    ]
    private static let months: Set<String> = ["january", "february", "march", "april", "may", "june", "july", "august", "september",
                                              "october", "november", "december", "jan", "feb", "sept", "oct", "nov", "dec"]
    private static let yearLeads: Set<String> = ["in", "since", "by", "from", "until", "till", "of", "year", "before", "after"]
    /// Words after a number that mean it's not a plain count ("the nineteen nineties", "twenty something").
    private static let blockers: Set<String> = ["nineties", "eighties", "seventies", "sixties", "fifties", "forties", "thirties",
                                                "twenties", "hundreds", "thousands", "something", "ish", "odd"]
    /// Units that read better as digits even for small numbers ("5 minutes", "8 GB").
    private static let measures: [String: String] = [
        "ms": "ms", "millisecond": "milliseconds", "milliseconds": "milliseconds", "second": "seconds", "seconds": "seconds",
        "secs": "seconds", "minute": "minutes", "minutes": "minutes", "mins": "minutes", "hour": "hours", "hours": "hours",
        "hrs": "hours", "gb": "GB", "gigs": "GB", "gigabytes": "GB", "mb": "MB", "megabytes": "MB", "kb": "KB", "tb": "TB",
        "terabytes": "TB", "px": "px", "pixels": "px", "fps": "fps", "cores": "cores", "lakh": "lakh", "lakhs": "lakh",
        "crore": "crore", "crores": "crore", "km": "km", "kilometers": "km", "kilometres": "km", "kg": "kg", "kilos": "kg",
    ]

    private struct Token { let text: String; let lower: String; let range: NSRange }
    private enum Last { case none, unit, teen, tens, hundred, scale }
    private struct Segment {
        var first: Int, last: Int          // token indices (inclusive)
        var value: Int
        var ordinal = false
        var startsWithA = false
        var decimal: String? = nil         // "2.5"
        var digits: String? = nil          // "9876543210"
        var words: Int { last - first + 1 }
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"[A-Za-z]+(?:'[A-Za-z]+)?|\d+(?:[.,:]\d+)*"#)

    static func apply(_ text: String) -> String {
        var t = digitsWithUnits(text)
        // Quick exit when no number word is present (most dictations).
        let words = t.lowercased().components(separatedBy: CharacterSet.letters.inverted)
        guard words.contains(where: { isNumberWord($0) }) else { return t }
        let ns = t as NSString
        let tokens = wordRegex.matches(in: t, range: NSRange(location: 0, length: ns.length)).map {
            Token(text: ns.substring(with: $0.range), lower: ns.substring(with: $0.range).lowercased(), range: $0.range)
        }
        var edits: [(NSRange, String)] = []
        var i = 0
        while i < tokens.count {
            guard isNumberWord(tokens[i].lower) || (tokens[i].lower == "a" && i + 1 < tokens.count && ["hundred", "thousand"].contains(tokens[i + 1].lower)) else { i += 1; continue }
            // A run of number words joined only by spaces or hyphens.
            var j = i
            while j + 1 < tokens.count, joined(tokens[j], tokens[j + 1], in: ns),
                  isNumberWord(tokens[j + 1].lower) || ["and", "point", "oh"].contains(tokens[j + 1].lower) { j += 1 }
            while j > i, ["and", "point", "oh"].contains(tokens[j].lower) { j -= 1 }
            if let edit = convert(tokens: tokens, from: i, to: j, in: ns) {
                edits.append(edit)
                // A conversion can reach past the run ("twenty dollars and fifty cents"): skip what it covered.
                let end = edit.0.location + edit.0.length
                var k = j + 1
                while k < tokens.count, tokens[k].range.location < end { k += 1 }
                i = k
            } else {
                i = j + 1
            }
        }
        // Apply back to front; never apply an edit that overlaps another or falls outside the text.
        var limit = ns.length
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            guard range.location >= 0, range.length >= 0, range.location + range.length <= limit else { continue }
            t = (t as NSString).replacingCharacters(in: range, with: replacement)
            limit = range.location
        }
        return t
    }

    private static func isNumberWord(_ w: String) -> Bool {
        units[w] != nil || teens[w] != nil || tens[w] != nil || scales[w] != nil || w == "hundred" || ordinals[w] != nil
    }

    private static func joined(_ a: Token, _ b: Token, in ns: NSString) -> Bool {
        let gap = ns.substring(with: NSRange(location: a.range.location + a.range.length, length: b.range.location - a.range.location - a.range.length))
        return gap == " " || gap == "-"
    }

    // MARK: Parsing

    private static func parse(_ tokens: [Token], _ from: Int, _ to: Int) -> [Segment] {
        let words = tokens[from...to].map(\.lower)
        // Three or more single digits in a row are read out one by one (phone numbers, codes, OTPs).
        if words.count >= 3, words.allSatisfy({ units[$0] != nil || $0 == "oh" }) {
            let d = words.map { $0 == "oh" ? "0" : String(units[$0]!) }.joined()
            return [Segment(first: from, last: to, value: Int(d.prefix(18)) ?? 0, digits: d)]
        }
        var segments: [Segment] = []
        var k = from
        while k <= to {
            var total = 0, current = 0, last = Last.none, largestScale = Int.max
            var seg = Segment(first: k, last: k, value: 0)
            var j = k
            if tokens[j].lower == "a", j + 1 <= to, ["hundred", "thousand"].contains(tokens[j + 1].lower) {
                seg.startsWithA = true; current = 1; last = .unit; j += 1
            }
            while j <= to {
                var w = tokens[j].lower
                var isOrdinal = false
                if let card = ordinals[w] {
                    // "second" only counts as an ordinal after tens ("twenty second") when it's a date; handled by the caller.
                    w = card; isOrdinal = true
                }
                if let u = units[w] {
                    if w == "zero" && last != .none { break }
                    if last == .tens && current % 10 != 0 { break }
                    guard [.none, .tens, .hundred, .scale].contains(last) else { break }
                    current += u; last = .unit
                } else if let v = teens[w] {
                    guard [.none, .hundred, .scale].contains(last) else { break }
                    current += v; last = .teen
                } else if let v = tens[w] {
                    guard [.none, .hundred, .scale].contains(last) else { break }
                    current += v; last = .tens
                } else if w == "hundred" {
                    if last == .none { current = 100 } else if [.unit, .teen, .tens].contains(last) { current = (current % 100 == 0 ? max(current, 1) : current) * 100 } else { break }
                    if current > 9900 { break }
                    last = .hundred
                } else if let s = scales[w] {
                    guard [.unit, .teen, .tens, .hundred].contains(last), current > 0, s < largestScale else { break }
                    total += current * s; current = 0; last = .scale; largestScale = s
                } else if w == "and" {
                    guard last == .hundred || last == .scale, j + 1 <= to, let next = Optional(tokens[j + 1].lower),
                          units[next] != nil || teens[next] != nil || tens[next] != nil else { break }
                    j += 1; continue
                } else if w == "point" {
                    var d = "", m = j + 1
                    while m <= to, let u = units[tokens[m].lower] ?? (tokens[m].lower == "oh" ? 0 : nil) { d += String(u); m += 1 }
                    guard !d.isEmpty, last != .none else { break }
                    seg.decimal = "\(total + current).\(d)"; j = m; break
                } else { break }
                j += 1
                if isOrdinal { seg.ordinal = true; break }
            }
            if j == k || (seg.startsWithA && j == k + 1) { k += 1; continue }   // nothing parsed here
            seg.last = j - 1
            seg.value = total + current
            segments.append(seg)
            k = j
        }
        return segments
    }

    // MARK: Deciding

    private static func convert(tokens: [Token], from: Int, to: Int, in ns: NSString) -> (NSRange, String)? {
        let segs = parse(tokens, from, to)
        guard !segs.isEmpty else { return nil }
        let prev = from > 0 && joinedLoosely(tokens[from - 1], tokens[from], in: ns) ? tokens[from - 1].lower : ""
        let prev2 = from > 1 ? tokens[from - 2].lower : ""
        func next(after seg: Segment) -> Token? {
            let n = seg.last + 1
            return n < tokens.count && joinedLoosely(tokens[seg.last], tokens[n], in: ns) ? tokens[n] : nil
        }
        func range(_ a: Int, _ b: Int) -> NSRange {
            NSRange(location: tokens[a].range.location, length: tokens[b].range.location + tokens[b].range.length - tokens[a].range.location)
        }

        // Dates: "October twenty first", "October twenty first twenty twenty five", "on the twenty first of October".
        if months.contains(prev) || (prev == "the" && months.contains(prev2)) {
            let day = segs[0]
            // "October first", "October 21"; a bare "October one of us" is not a date.
            guard (1...31).contains(day.value), day.decimal == nil, day.digits == nil,
                  day.ordinal || day.value >= 10 || segs.count > 1 else { return nil }
            var out = String(day.value), end = day.last
            if segs.count > 1, let (year, last) = year(segs, from: 1) { out += ", \(year)"; end = last }
            else if segs.count > 1 { return nil }
            return (range(day.first, end), out)
        }
        // Years: "in twenty twenty five", "since nineteen ninety nine".
        if yearLeads.contains(prev), let (y, last) = year(segs, from: 0), last == segs.last!.last,
           segs.count == 2 || next(after: segs.last!).map({ $0.lower.first?.isLetter != true }) ?? true {
            return (range(segs[0].first, last), y)
        }
        // Times: "three thirty pm", "seven pm", "ten fifteen a m".
        if let nt = next(after: segs.last!), let suffix = meridiem(nt, tokens: tokens, in: ns) {
            let h = segs[0]
            guard (1...12).contains(h.value), h.decimal == nil, h.digits == nil, !h.ordinal else { return nil }
            if segs.count == 1 { return (NSRange(location: tokens[h.first].range.location, length: suffix.end - tokens[h.first].range.location), "\(h.value) \(suffix.text)") }
            if segs.count == 2, (0...59).contains(segs[1].value), segs[1].words <= 2 {
                return (NSRange(location: tokens[h.first].range.location, length: suffix.end - tokens[h.first].range.location),
                        "\(h.value):\(String(format: "%02d", segs[1].value)) \(suffix.text)")
            }
            return nil
        }
        // Several numbers back to back with no structure ("twenty four seven", "fifty fifty"): leave as said.
        guard segs.count == 1, let seg = segs.first else { return nil }
        let n = next(after: seg)
        let nl = n?.lower ?? ""
        if blockers.contains(nl) { return nil }
        let r = range(seg.first, seg.last)

        if let d = seg.digits { return (r, d) }
        if let d = seg.decimal {
            if let (sym, unitRange) = currency(n, tokens: tokens, after: seg.last, in: ns) { return (NSRange(location: r.location, length: unitRange - r.location), sym + d) }
            if nl == "percent" { return (NSRange(location: r.location, length: n!.range.location + n!.range.length - r.location), d + "%") }
            return (r, d)
        }
        if seg.ordinal {
            // "twenty second" is usually a duration ("a twenty second clip"), so ordinals need 11+ and not "-second".
            guard seg.value >= 11, tokens[seg.last].lower != "second" else { return nil }
            return (r, "\(seg.value)\(suffix(seg.value))")
        }
        if nl == "percent" || (nl == "per" && seg.last + 2 < tokens.count && tokens[seg.last + 2].lower == "cent") {
            let end = nl == "percent" ? n!.range : tokens[seg.last + 2].range
            return (NSRange(location: r.location, length: end.location + end.length - r.location), "\(grouped(seg.value))%")
        }
        if let (sym, end) = currency(n, tokens: tokens, after: seg.last, in: ns) {
            // "twenty dollars and fifty cents" → $20.50
            if let (cents, centsEnd) = cents(tokens: tokens, after: seg.last + 1, in: ns) {
                return (NSRange(location: r.location, length: centsEnd - r.location), sym + grouped(seg.value) + String(format: ".%02d", cents))
            }
            return (NSRange(location: r.location, length: end - r.location), sym + grouped(seg.value))
        }
        if nl == "k" || nl == "x" {
            return (NSRange(location: r.location, length: n!.range.location + n!.range.length - r.location), "\(grouped(seg.value))\(nl)")
        }
        if let unit = measures[nl], !(seg.value == 1 && ["second", "minute", "hour"].contains(nl)) {
            // "a second" / "one minute" stay words; "five minutes", "8 GB" become digits.
            if seg.startsWithA { return nil }
            return (NSRange(location: r.location, length: n!.range.location + n!.range.length - r.location), "\(grouped(seg.value)) \(unit)")
        }
        guard seg.value >= 10, !seg.startsWithA else { return nil }
        return (r, grouped(seg.value))
    }

    private static func joinedLoosely(_ a: Token, _ b: Token, in ns: NSString) -> Bool {
        let gap = ns.substring(with: NSRange(location: a.range.location + a.range.length, length: b.range.location - a.range.location - a.range.length))
        return gap.allSatisfy { $0 == " " || $0 == "-" } && !gap.isEmpty
    }

    private static func year(_ segs: [Segment], from k: Int) -> (String, Int)? {
        // "twenty twenty five" → 2025, "nineteen ninety nine" → 1999, "two thousand twenty five" → 2025.
        if k + 1 < segs.count, [19, 20].contains(segs[k].value), segs[k].words == 1, (10...99).contains(segs[k + 1].value),
           segs[k + 1].decimal == nil, !segs[k + 1].ordinal {
            return ("\(segs[k].value)\(segs[k + 1].value)", segs[k + 1].last)
        }
        if k < segs.count, (1900...2100).contains(segs[k].value), !segs[k].ordinal { return (String(segs[k].value), segs[k].last) }
        return nil
    }

    private static func meridiem(_ t: Token, tokens: [Token], in ns: NSString) -> (text: String, end: Int)? {
        switch t.lower {
        case "am", "pm": return (t.lower.uppercased(), t.range.location + t.range.length)
        case "a", "p":
            // "a m" / "p m" / "a.m."
            let rest = ns.substring(from: t.range.location + t.range.length)
            if let m = rest.range(of: #"^(?:\.\s?m\.|\s?m\b)"#, options: [.regularExpression, .caseInsensitive]) {
                return (t.lower == "a" ? "AM" : "PM", t.range.location + t.range.length + rest.distance(from: rest.startIndex, to: m.upperBound))
            }
            return nil
        default: return nil
        }
    }

    private static func currency(_ n: Token?, tokens: [Token], after: Int, in ns: NSString) -> (String, Int)? {
        guard let n else { return nil }
        let end = n.range.location + n.range.length
        switch n.lower {
        case "dollars", "dollar", "bucks": return ("$", end)
        case "rupees", "rupee", "rs": return ("₹", end)
        case "euros", "euro": return ("€", end)
        default: return nil
        }
    }

    private static func cents(tokens: [Token], after unit: Int, in ns: NSString) -> (Int, Int)? {
        var k = unit + 1
        guard k + 1 < tokens.count, tokens[k].lower == "and" else { return nil }
        k += 1
        var value = 0
        if let t = tens[tokens[k].lower] { value = t; k += 1; if k < tokens.count, let u = units[tokens[k].lower], u > 0 { value += u; k += 1 } }
        else if let v = teens[tokens[k].lower] ?? units[tokens[k].lower] { value = v; k += 1 }
        else { return nil }
        guard k < tokens.count, ["cents", "cent", "paise"].contains(tokens[k].lower), value < 100 else { return nil }
        return (value, tokens[k].range.location + tokens[k].range.length)
    }

    private static func suffix(_ n: Int) -> String {
        if (11...13).contains(n % 100) { return "th" }
        switch n % 10 { case 1: return "st"; case 2: return "nd"; case 3: return "rd"; default: return "th" }
    }

    private static func grouped(_ n: Int) -> String {
        guard n >= 1000 else { return String(n) }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    /// Digits the speech engine already wrote: "50 percent" → 50%, "20 dollars" → $20, "3 pm" → 3 PM.
    static func digitsWithUnits(_ s: String) -> String {
        // A whole written number: 1,200 / 2.5 / 40 (never just the "200" of "1,200").
        let num = #"(?<![\d.,])(\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?)"#
        var t = s.replacingOccurrences(of: "(?i)" + num + #"\s?(?:percent|per cent)\b"#, with: "$1%", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)" + num + #"\s?(?:dollars?|bucks)\b"#, with: "\\$$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)" + num + #"\s?(?:rupees?)\b"#, with: "₹$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?i)\b(\d{1,2}(?::\d{2})?)\s?(a|p)(?:\.\s?m\.|\s?m\b)"#, with: "$1 $2M", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(\d{1,2}(?::\d{2})?) (a|p)M\b"#, with: "$1 $2M", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(\d+)\s(?:k|K)\b"#, with: "$1k", options: .regularExpression)
        // "3 aM" → "3 AM" (the template keeps the original letter's case).
        t = t.replacingOccurrences(of: #"\b(\d{1,2}(?::\d{2})?) aM\b"#, with: "$1 AM", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(\d{1,2}(?::\d{2})?) pM\b"#, with: "$1 PM", options: .regularExpression)
        return t
    }
}
