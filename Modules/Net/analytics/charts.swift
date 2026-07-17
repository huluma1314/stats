//
//  charts.swift
//  Net
//

import Cocoa
import Foundation
import Kit

public struct ChartPoint: Equatable {
    public let timestamp: Date
    public let download: UInt64
    public let upload: UInt64

    public var total: UInt64 { self.download + self.upload }

    public init(timestamp: Date, download: UInt64, upload: UInt64) {
        self.timestamp = timestamp
        self.download = download
        self.upload = upload
    }
}

public struct HeatmapCell: Equatable {
    public let start: Date
    public let end: Date
    public let download: UInt64
    public let upload: UInt64
    public let intensity: Double

    public var total: UInt64 { self.download + self.upload }

    public init(start: Date, end: Date, download: UInt64, upload: UInt64, intensity: Double) {
        self.start = start
        self.end = end
        self.download = download
        self.upload = upload
        self.intensity = intensity
    }
}

public enum TrafficChartGeometry {
    public static let contentInsets = NSEdgeInsets(top: 12, left: 36, bottom: 24, right: 12)

    public static func points(from buckets: [TrafficBucket]) -> [ChartPoint] {
        buckets.map {
            ChartPoint(timestamp: $0.start, download: $0.download, upload: $0.upload)
        }
    }

    public static func heatmapCells(from buckets: [TrafficBucket]) -> [HeatmapCell] {
        let maxTotal = max(buckets.map { $0.download + $0.upload }.max() ?? 1, 1)
        return buckets.map {
            HeatmapCell(
                start: $0.start,
                end: $0.end,
                download: $0.download,
                upload: $0.upload,
                intensity: Double($0.download + $0.upload) / Double(maxTotal)
            )
        }
    }

    public static func normalizeSelection(startX: CGFloat, endX: CGFloat, bounds: CGRect) -> CGRect {
        let minX = min(startX, endX)
        let maxX = max(startX, endX)
        let left = max(bounds.minX, minX)
        let right = min(bounds.maxX, maxX)
        return CGRect(x: left, y: bounds.minY, width: max(0, right - left), height: bounds.height)
    }

    public static func plotRect(in bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.minX + self.contentInsets.left,
            y: bounds.minY + self.contentInsets.bottom,
            width: max(1, bounds.width - self.contentInsets.left - self.contentInsets.right),
            height: max(1, bounds.height - self.contentInsets.top - self.contentInsets.bottom)
        )
    }

    public static func xPosition(index: Int, count: Int, in plot: CGRect) -> CGFloat {
        guard count > 1 else { return plot.midX }
        return plot.minX + (plot.width * CGFloat(index) / CGFloat(count - 1))
    }

    public static func nearestIndex(at x: CGFloat, count: Int, in plot: CGRect) -> Int? {
        guard count > 0 else { return nil }
        if count == 1 { return 0 }
        let ratio = max(0, min(1, (x - plot.minX) / plot.width))
        return Int((ratio * CGFloat(count - 1)).rounded())
    }

    public static func selectionInterval(
        from startX: CGFloat,
        to endX: CGFloat,
        points: [ChartPoint],
        in bounds: CGRect
    ) -> DateInterval? {
        guard points.count >= 2 else { return nil }
        let plot = self.plotRect(in: bounds)
        guard let startIndex = self.nearestIndex(at: min(startX, endX), count: points.count, in: plot),
              let endIndex = self.nearestIndex(at: max(startX, endX), count: points.count, in: plot) else {
            return nil
        }
        let start = points[min(startIndex, endIndex)].timestamp
        let end = points[max(startIndex, endIndex)].timestamp
        return DateInterval(start: start, end: max(start.addingTimeInterval(1), end))
    }

    public static func heatmapIndex(at point: CGPoint, cells: [HeatmapCell], in bounds: CGRect) -> Int? {
        guard !cells.isEmpty else { return nil }
        let plot = self.plotRect(in: bounds)
        guard plot.contains(point) else { return nil }
        let columns = max(1, Int(ceil(sqrt(Double(cells.count)))))
        let rows = max(1, Int(ceil(Double(cells.count) / Double(columns))))
        let cellWidth = plot.width / CGFloat(columns)
        let cellHeight = plot.height / CGFloat(rows)
        let column = Int((point.x - plot.minX) / cellWidth)
        let rowFromTop = Int((plot.maxY - point.y) / cellHeight)
        let index = rowFromTop * columns + column
        return cells.indices.contains(index) ? index : nil
    }
}

internal final class TrafficTimelineChartView: NSView {
    var points: [ChartPoint] = [] {
        didSet { self.needsDisplay = true }
    }
    var onSelection: ((DateInterval?) -> Void)?
    var onHover: ((ChartPoint?) -> Void)?

    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let plot = TrafficChartGeometry.plotRect(in: self.bounds)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        context.stroke(plot)

        guard !self.points.isEmpty else {
            let text = localizedString("No chart data") as NSString
            text.draw(
                at: CGPoint(x: plot.midX - 40, y: plot.midY - 8),
                withAttributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 12)
                ]
            )
            return
        }

        let maxValue = max(self.points.map(\.total).max() ?? 1, 1)
        let downloadPath = CGMutablePath()
        let uploadPath = CGMutablePath()
        for (index, point) in self.points.enumerated() {
            let x = TrafficChartGeometry.xPosition(index: index, count: self.points.count, in: plot)
            let downloadY = plot.maxY - (plot.height * CGFloat(point.download) / CGFloat(maxValue))
            let uploadY = plot.maxY - (plot.height * CGFloat(point.upload) / CGFloat(maxValue))
            if index == 0 {
                downloadPath.move(to: CGPoint(x: x, y: downloadY))
                uploadPath.move(to: CGPoint(x: x, y: uploadY))
            } else {
                downloadPath.addLine(to: CGPoint(x: x, y: downloadY))
                uploadPath.addLine(to: CGPoint(x: x, y: uploadY))
            }
        }

        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(1.5)
        context.addPath(downloadPath)
        context.strokePath()

        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.addPath(uploadPath)
        context.strokePath()

        if let start = self.dragStart, let current = self.dragCurrent {
            let rect = TrafficChartGeometry.normalizeSelection(startX: start.x, endX: current.x, bounds: plot)
            context.setFillColor(NSColor.systemBlue.withAlphaComponent(0.15).cgColor)
            context.fill(rect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        self.dragStart = self.convert(event.locationInWindow, from: nil)
        self.dragCurrent = self.dragStart
        self.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        self.dragCurrent = self.convert(event.locationInWindow, from: nil)
        self.needsDisplay = true
        if let point = self.dragCurrent,
           let index = TrafficChartGeometry.nearestIndex(
            at: point.x,
            count: self.points.count,
            in: TrafficChartGeometry.plotRect(in: self.bounds)
           ) {
            self.onHover?(self.points[index])
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            self.dragStart = nil
            self.dragCurrent = nil
            self.needsDisplay = true
        }
        guard let start = self.dragStart else { return }
        let end = self.convert(event.locationInWindow, from: nil)
        if abs(end.x - start.x) < 4 {
            self.onSelection?(nil)
            return
        }
        self.onSelection?(
            TrafficChartGeometry.selectionInterval(
                from: start.x,
                to: end.x,
                points: self.points,
                in: self.bounds
            )
        )
    }

    override func mouseMoved(with event: NSEvent) {
        let location = self.convert(event.locationInWindow, from: nil)
        guard let index = TrafficChartGeometry.nearestIndex(
            at: location.x,
            count: self.points.count,
            in: TrafficChartGeometry.plotRect(in: self.bounds)
        ) else {
            self.onHover?(nil)
            return
        }
        self.onHover?(self.points[index])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.trackingAreas.forEach(self.removeTrackingArea)
        self.addTrackingArea(
            NSTrackingArea(
                rect: self.bounds,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }
}

internal final class TrafficHeatmapView: NSView {
    var cells: [HeatmapCell] = [] {
        didSet { self.needsDisplay = true }
    }
    var onSelect: ((HeatmapCell?) -> Void)?
    var onHover: ((HeatmapCell?) -> Void)?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
        let plot = TrafficChartGeometry.plotRect(in: self.bounds)
        guard !self.cells.isEmpty else {
            let text = localizedString("No chart data") as NSString
            text.draw(
                at: CGPoint(x: plot.midX - 40, y: plot.midY - 8),
                withAttributes: [
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 12)
                ]
            )
            return
        }

        let columns = max(1, Int(ceil(sqrt(Double(self.cells.count)))))
        let rows = max(1, Int(ceil(Double(self.cells.count) / Double(columns))))
        let cellWidth = plot.width / CGFloat(columns)
        let cellHeight = plot.height / CGFloat(rows)
        for (index, cell) in self.cells.enumerated() {
            let column = index % columns
            let row = index / columns
            let rect = CGRect(
                x: plot.minX + CGFloat(column) * cellWidth + 1,
                y: plot.minY + CGFloat(row) * cellHeight + 1,
                width: max(1, cellWidth - 2),
                height: max(1, cellHeight - 2)
            )
            NSColor.systemBlue.withAlphaComponent(0.15 + 0.75 * cell.intensity).setFill()
            rect.fill()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        if let index = TrafficChartGeometry.heatmapIndex(at: point, cells: self.cells, in: self.bounds) {
            self.onSelect?(self.cells[index])
        } else {
            self.onSelect?(nil)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        if let index = TrafficChartGeometry.heatmapIndex(at: point, cells: self.cells, in: self.bounds) {
            self.onHover?(self.cells[index])
        } else {
            self.onHover?(nil)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        self.trackingAreas.forEach(self.removeTrackingArea)
        self.addTrackingArea(
            NSTrackingArea(
                rect: self.bounds,
                options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }
}
