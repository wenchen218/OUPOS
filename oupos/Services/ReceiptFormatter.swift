import Foundation
import UIKit

/// Draw the whole receipt as monochrome pixels so Chinese glyphs print correctly
/// even when an ESC/POS printer does not have a Traditional Chinese code page.
/// All dimensions are proportional to the printer's 384-/576-dot paper width.
enum ReceiptFormatter {
    struct ReceiptContent {
        struct Item {
            let name: String
            let quantity: Int
            let subtotal: Int
            let modifiers: [String]
            let note: String?
        }

        let businessName: String
        let orderType: String
        let number: String
        let placedAt: String
        let paymentMethod: String
        let note: String
        let items: [Item]
        let quantity: Int
        let total: Int
    }

    static func content(order: POSOrder, businessName: String?) -> ReceiptContent {
        let shopName = businessName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_TW")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy/MM/dd HH:mm"

        return ReceiptContent(
            businessName: shopName.isEmpty ? "OUPOS" : shopName,
            orderType: order.table,
            number: "#" + order.number,
            placedAt: formatter.string(from: order.createdAt),
            paymentMethod: order.paymentMethod,
            note: order.note.trimmingCharacters(in: .whitespacesAndNewlines),
            items: order.lines.map { line in
                ReceiptContent.Item(name: line.name, quantity: line.quantity,
                                    subtotal: line.subtotal,
                                    modifiers: line.modifiers.map { printableModifierName($0) },
                                    note: line.note)
            },
            quantity: order.totalQuantity,
            total: order.total
        )
    }

    /// Strip only the legacy trailing topping surcharge (e.g. "加蛋 ×5 +75").
    /// Product subtotals already include topping costs and must never be modified.
    static func printableModifierName(_ value: String) -> String {
        guard let priceRange = value.range(of: #" \+\d+$"#, options: .regularExpression) else {
            return value
        }
        return String(value[..<priceRange.lowerBound])
    }

    // Some ESC/POS firmware mirrors raster rows. This setting corrects the user's
    // current printer; turn it off in 出單機設定 for printers with standard raster orientation.
    static let mirrorSettingKey = "oupos.receipt.correctHorizontalMirror"
    /// This printer feeds the bottom of a raster block first. Correct its vertical
    /// ordering at output time so the business name prints before the OUPOS logo.
    static let reverseRowSettingKey = "oupos.receipt.correctVerticalOrder"

    static func makeReceipt(order: POSOrder, width: Int, businessName: String? = nil,
                            correctHorizontalMirror: Bool = true,
                            correctVerticalOrder: Bool = true) -> Data {
        let pixelsWide = width == 384 ? 384 : 576
        let receipt = content(order: order, businessName: businessName)

        // First calculate text-wrapped heights; then render at exact dot resolution.
        var measuring = Painter(width: pixelsWide, context: nil)
        measuring.draw(receipt)
        let pixelsHigh = max(1, Int(ceil(measuring.y + measuring.units(28))))

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(pixelsWide), height: CGFloat(pixelsHigh)), format: format
        ).image { renderer in
            renderer.cgContext.setFillColor(UIColor.white.cgColor)
            renderer.cgContext.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelsWide),
                                           height: CGFloat(pixelsHigh)))
            var painter = Painter(width: pixelsWide, context: renderer.cgContext)
            painter.draw(receipt)
        }

        guard let bitmap = image.cgImage else { return Data() }
        let rowBytes = pixelsWide / 8
        var gray = [UInt8](repeating: 255, count: pixelsWide * pixelsHigh)
        gray.withUnsafeMutableBytes { buffer in
            guard let pointer = buffer.baseAddress,
                  let cgContext = CGContext(
                    data: pointer, width: pixelsWide, height: pixelsHigh,
                    bitsPerComponent: 8, bytesPerRow: pixelsWide,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return }
            cgContext.setFillColor(gray: 1, alpha: 1)
            cgContext.fill(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
            cgContext.translateBy(x: 0, y: CGFloat(pixelsHigh))
            cgContext.scaleBy(x: 1, y: -1)
            cgContext.draw(bitmap, in: CGRect(x: 0, y: 0, width: CGFloat(pixelsWide),
                                               height: CGFloat(pixelsHigh)))
        }

        // ESC @ initializes the printer. GS v 0 prints bit-packed raster rows.
        // Chunks are adjacent; do NOT insert an LF between them (it creates gaps).
        var output = Data([0x1B, 0x40])
        for startY in stride(from: 0, to: pixelsHigh, by: 240) {
            let blockHeight = min(240, pixelsHigh - startY)
            output.append(contentsOf: [0x1D, 0x76, 0x30, 0x00,
                                       UInt8(rowBytes & 0xFF), UInt8((rowBytes >> 8) & 0xFF),
                                       UInt8(blockHeight & 0xFF), UInt8((blockHeight >> 8) & 0xFF)])
            for y in startY..<(startY + blockHeight) {
                // Reverse the physical raster *rows*, not text or drawing geometry.
                // The printer observed in use prints the last row first, so sending
                // the footer first restores the intended shop-name-first output.
                let imageY = correctVerticalOrder ? (pixelsHigh - 1 - y) : y
                for xb in 0..<rowBytes {
                    var bits: UInt8 = 0
                    for bit in 0..<8 {
                        let paperX = xb * 8 + bit
                        // Keep glyphs, columns, and the footer logo together when correcting
                        // a printer's mirrored output; swapping just the columns breaks text.
                        let imageX = correctHorizontalMirror ? (pixelsWide - 1 - paperX) : paperX
                        if gray[imageY * pixelsWide + imageX] < 165 {
                            bits |= 1 << (7 - bit)
                        }
                    }
                    output.append(bits)
                }
            }
        }
        output.append(contentsOf: [0x0A, 0x0A, 0x1D, 0x56, 0x00]) // feed & cut
        return output
    }

    /// Shared measuring/drawing pass. No printer-dependent CJK text encodings.
    private struct Painter {
        let width: CGFloat
        let scale: CGFloat
        let margin: CGFloat
        let context: CGContext?
        var y: CGFloat

        init(width: Int, context: CGContext?) {
            self.width = CGFloat(width)
            scale = CGFloat(width) / 576
            margin = CGFloat(width) == 384 ? 21 : 32
            self.context = context
            y = CGFloat(width) == 384 ? 16 : 23
        }

        var bodyWidth: CGFloat { width - 2 * margin }
        func units(_ value: CGFloat) -> CGFloat { max(1, value * scale) }
        func type(_ size: CGFloat, bold: Bool = false) -> UIFont {
            .systemFont(ofSize: units(size), weight: bold ? .bold : .regular)
        }
        func textHeight(_ value: String, font: UIFont, constrainedTo maximumWidth: CGFloat) -> CGFloat {
            guard !value.isEmpty else { return font.lineHeight }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            let rect = (value as NSString).boundingRect(
                with: CGSize(width: max(1, maximumWidth), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .paragraphStyle: paragraph], context: nil
            )
            return ceil(max(font.lineHeight, rect.height)) + units(2)
        }
        func write(_ value: String, font: UIFont, rect: CGRect, alignment: NSTextAlignment = .left) {
            guard context != nil else { return }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = alignment
            paragraph.lineBreakMode = .byCharWrapping
            (value as NSString).draw(
                with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font, .foregroundColor: UIColor.black, .paragraphStyle: paragraph],
                context: nil
            )
        }
        mutating func centered(_ value: String, font: UIFont, after: CGFloat) {
            let h = textHeight(value, font: font, constrainedTo: bodyWidth)
            write(value, font: font, rect: CGRect(x: margin, y: y, width: bodyWidth, height: h), alignment: .center)
            y += h + units(after)
        }
        mutating func pair(_ left: String, _ right: String, font: UIFont,
                           rightFont: UIFont? = nil, after: CGFloat, minimumRightShare: CGFloat = 0) {
            let rhsFont = rightFont ?? font
            let gap = units(12)
            let naturalRight = (right as NSString).size(withAttributes: [.font: rhsFont]).width + units(4)
            // Leave a readable left column for Chinese item names. If long, wrap
            // within the available space instead of clipping or overlapping prices.
            let rightWidth = min(bodyWidth * 0.65, max(bodyWidth * minimumRightShare, naturalRight))
            let leftWidth = max(units(45), bodyWidth - rightWidth - gap)
            let realRightWidth = bodyWidth - leftWidth - gap
            let h = max(textHeight(left, font: font, constrainedTo: leftWidth),
                        textHeight(right, font: rhsFont, constrainedTo: realRightWidth))
            write(left, font: font, rect: CGRect(x: margin, y: y, width: leftWidth, height: h))
            write(right, font: rhsFont,
                  rect: CGRect(x: margin + leftWidth + gap, y: y,
                               width: realRightWidth, height: h), alignment: .right)
            y += h + units(after)
        }
        mutating func single(_ value: String, font: UIFont, indent: CGFloat = 0, after: CGFloat) {
            let x = margin + units(indent)
            let available = bodyWidth - units(indent)
            let h = textHeight(value, font: font, constrainedTo: available)
            write(value, font: font, rect: CGRect(x: x, y: y, width: available, height: h))
            y += h + units(after)
        }
        mutating func separator(before: CGFloat, after: CGFloat) {
            y += units(before)
            if let context {
                context.setFillColor(UIColor.black.cgColor)
                // Use equal margins on both sides. A slightly shorter rule also
                // prevents clipping on printers with narrower printable regions.
                let lineWidth = min(bodyWidth, width * 0.82)
                context.fill(CGRect(x: (width - lineWidth) / 2, y: y,
                                    width: lineWidth, height: units(3)))
            }
            y += units(3 + after)
        }
        mutating func branding() {
            y += units(64)
            // Converted from the user-supplied OUPOS.png. The asset contains black ink
            // on a white background so the thermal printer does not print a solid block.
            let iconSide = units(66)
            let gap = units(15)
            let font = type(54, bold: true)
            let word = "OUPOS"
            let wordWidth = ceil((word as NSString).size(withAttributes: [.font: font]).width)
            let totalWidth = iconSide + gap + wordWidth
            let startX = (width - totalWidth) / 2
            if context != nil, let logo = UIImage(named: "ReceiptLogo") {
                logo.draw(in: CGRect(x: startX, y: y, width: iconSide, height: iconSide))
            }
            write(word, font: font,
                  rect: CGRect(x: startX + iconSide + gap, y: y + (iconSide - font.lineHeight) / 2,
                               width: wordWidth + units(3), height: font.lineHeight + units(5)))
            y += iconSide + units(23)
        }
        mutating func draw(_ receipt: ReceiptContent) {
            centered(receipt.businessName, font: type(41, bold: true), after: 17)
            pair(receipt.orderType, receipt.number, font: type(45, bold: true), after: 16,
                 minimumRightShare: 0.48)
            pair("下單時間", receipt.placedAt, font: type(33), after: 12,
                 minimumRightShare: 0.56)
            pair("付款方式", receipt.paymentMethod, font: type(33),
                 after: receipt.note.isEmpty ? 0 : 17)
            if !receipt.note.isEmpty {
                centered("備註：" + receipt.note, font: type(50, bold: true), after: 0)
            }
            separator(before: 23, after: 26)
            for item in receipt.items {
                pair("\(item.name)x\(item.quantity)", "\(item.subtotal)",
                     font: type(54, bold: true), after: 5, minimumRightShare: 0.19)
                for modifier in item.modifiers {
                    single("**" + modifier, font: type(45, bold: true), after: 5)
                }
                if let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
                    single("**備註：" + note, font: type(43), after: 5)
                }
                y += units(14)
            }
            separator(before: 20, after: 22)
            pair("數量", String(receipt.quantity), font: type(46), after: 6)
            pair("金額", String(receipt.total), font: type(46), after: 0)
            branding()
        }
    }
}
