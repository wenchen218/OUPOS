import Charts
import SwiftUI

enum ReportTab: String, CaseIterable, Identifiable {
    case revenue = "營業額"
    case sales = "銷售統計"
    var id: String { rawValue }
}

struct ReportsView: View {
    @EnvironmentObject private var store: POSStore
    @State private var selectedTab: ReportTab = .revenue
    @State private var selectedOrder: POSOrder?
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var showsRangeEditor = false

    init() {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: Date())
        _startAt = State(initialValue: start)
        _endAt = State(initialValue: calendar.date(byAdding: .day, value: 1, to: start) ?? Date())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                ForEach(ReportTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                        selectedOrder = nil
                    } label: {
                        VStack(spacing: 8) {
                            Text(tab.rawValue)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(POSColor.textPrimary)
                            Rectangle()
                                .fill(selectedTab == tab ? POSColor.selectedOrange : .clear)
                                .frame(height: 3)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { showsRangeEditor = true } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "calendar.badge.clock")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(POSColor.primaryStrong)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("查詢區間")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(POSColor.textSecondary)
                            Text(rangeLabel)
                                .font(.system(size: 14, weight: .bold).monospacedDigit())
                                .foregroundStyle(POSColor.textPrimary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(POSColor.textSecondary)
                    }
                    .padding(.horizontal, 13)
                    .frame(height: 44)
                    .background(POSColor.surfaceSecondary)
                    .overlay { RoundedRectangle(cornerRadius: 9).stroke(POSColor.border) }
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showsRangeEditor, arrowEdge: .top) {
                    ReportRangeEditor(startAt: $startAt, endAt: $endAt) {
                        showsRangeEditor = false
                        Task { await query() }
                    }
                    .presentationCompactAdaptation(.popover)
                }
                Button("查詢") { Task { await query() } }
                    .buttonStyle(.borderedProminent).tint(POSColor.primaryStrong)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .background(POSColor.surface)

            if selectedTab == .revenue {
                revenueContent
            } else {
                salesContent
            }
        }
    }

    private var revenueContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 16) {
                VStack(spacing: 16) {
                    HStack(spacing: 16) {
                        MetricCard(label: "區間營業額", value: "$\(store.report.revenue)", symbol: "dollarsign.circle.fill")
                        MetricCard(label: "總訂單數", value: "\(store.report.orderCount)", symbol: "doc.text.fill")
                    }
                    PaymentChart(payments: store.report.payments)
                }
                .frame(width: geometry.size.width * 0.37)

                Group {
                    if let selectedOrder {
                        OrderDetailPanel(order: selectedOrder) { self.selectedOrder = nil }
                    } else {
                        ReportOrdersTable(orders: store.report.orders) { order in
                            selectedOrder = store.loadOrderDetails(order)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(18)
        }
    }

    private var salesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                MetricCard(label: "商品種類", value: "\(store.productSales.productCount)", symbol: "square.grid.2x2.fill")
                MetricCard(label: "售出份數", value: "\(store.productSales.totalQuantity)", symbol: "takeoutbag.and.cup.and.straw.fill")
                MetricCard(label: "訂單數", value: "\(store.productSales.totalOrders)", symbol: "doc.text.fill")
                MetricCard(label: "商品小計", value: "$\(store.productSales.grossSales)", symbol: "dollarsign.circle.fill")
            }
            HStack {
                Text("商品").frame(maxWidth: .infinity, alignment: .leading)
                Text("份數").frame(width: 90, alignment: .trailing)
                Text("訂單數").frame(width: 90, alignment: .trailing)
                Text("金額").frame(width: 120, alignment: .trailing)
            }
            .font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 44).background(POSColor.primaryStrong)

            Group {
                if store.productSales.products.isEmpty {
                    EmptyStateView(symbol: "chart.bar.xaxis", message: "此區間沒有商品售出資料")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.productSales.products) { row in
                                HStack {
                                    Text(row.name).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
                                    Text("\(row.quantity) 份").monospacedDigit().frame(width: 90, alignment: .trailing)
                                    Text("\(row.orderCount)").monospacedDigit().frame(width: 90, alignment: .trailing)
                                    Text("$\(row.grossSales)").monospacedDigit().frame(width: 120, alignment: .trailing)
                                }
                                .padding(.horizontal, 16).frame(minHeight: 50)
                                Divider()
                            }
                        }
                    }
                }
            }
            .background(POSColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
    }

    private func query() async {
        guard endAt > startAt else {
            store.errorMessage = "結束時間必須晚於開始時間"
            return
        }
        guard endAt.timeIntervalSince(startAt) >= 30 * 60 else {
            store.errorMessage = "查詢區間至少需要 30 分鐘"
            return
        }
        selectedOrder = nil
        store.refreshReport(startAt: startAt, endAt: endAt)
    }

    private var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hant_TW")
        formatter.dateFormat = Calendar.current.isDate(startAt, inSameDayAs: endAt) ? "MM/dd HH:mm" : "MM/dd HH:mm"
        return "\(formatter.string(from: startAt))－\(formatter.string(from: endAt))"
    }
}

private struct ReportRangeEditor: View {
    @Binding var startAt: Date
    @Binding var endAt: Date
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("選擇報表區間")
                .font(.system(size: 21, weight: .bold))

            HStack(spacing: 8) {
                preset("今天", daysAgo: 0, length: 1)
                preset("昨天", daysAgo: 1, length: 1)
                preset("近 7 天", daysAgo: 6, length: 7)
                preset("近 30 天", daysAgo: 29, length: 30)
            }

            HStack(spacing: 12) {
                ReportDateTimeControl(title: "開始時間", value: $startAt)
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(POSColor.textSecondary)
                ReportDateTimeControl(title: "結束時間", value: $endAt)
            }

            if endAt <= startAt {
                Label("結束時間必須晚於開始時間", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(POSColor.danger)
            }

            Button("套用並查詢", action: apply)
                .buttonStyle(FilledActionButtonStyle(color: POSColor.primaryStrong, height: 46))
                .disabled(endAt <= startAt || endAt.timeIntervalSince(startAt) < 30 * 60)
        }
        .padding(20)
        .frame(width: 610)
        .background(POSColor.background)
    }

    private func preset(_ title: String, daysAgo: Int, length: Int) -> some View {
        Button(title) {
            let calendar = Calendar(identifier: .gregorian)
            let today = calendar.startOfDay(for: Date())
            startAt = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            endAt = calendar.date(byAdding: .day, value: length, to: startAt) ?? Date()
        }
        .buttonStyle(.bordered)
        .tint(POSColor.primaryStrong)
    }
}

private struct ReportDateTimeControl: View {
    let title: String
    @Binding var value: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(POSColor.textSecondary)
            HStack(spacing: 7) {
                adjustButton(symbol: "chevron.left", component: .day, amount: -1)
                VStack(spacing: 2) {
                    Text(value.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits)))
                        .font(.system(size: 15, weight: .bold))
                    Text(value.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)))
                        .font(.system(size: 22, weight: .bold).monospacedDigit())
                        .foregroundStyle(POSColor.primaryStrong)
                }
                .frame(minWidth: 126)
                adjustButton(symbol: "chevron.right", component: .day, amount: 1)
            }
            HStack(spacing: 8) {
                adjustButton(symbol: "minus", component: .minute, amount: -30)
                Text("每次 30 分鐘")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(POSColor.textSecondary)
                    .frame(maxWidth: .infinity)
                adjustButton(symbol: "plus", component: .minute, amount: 30)
            }
        }
        .padding(14)
        .background(POSColor.surface)
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(POSColor.border) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func adjustButton(symbol: String, component: Calendar.Component, amount: Int) -> some View {
        Button {
            value = Calendar(identifier: .gregorian).date(byAdding: component, value: amount, to: value) ?? value
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.bordered)
        .tint(POSColor.primaryStrong)
    }
}

private struct MetricCard: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(label, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(POSColor.textSecondary)
            Text(value)
                .font(.system(size: 31, weight: .bold).monospacedDigit())
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .posCard()
    }
}

private struct PaymentChart: View {
    let payments: [PaymentSlice]
    private let colors = [POSColor.primaryStrong, POSColor.selectedOrange, POSColor.success, POSColor.warning, Color.purple]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("各支付方式統計")
                .font(.system(size: 20, weight: .bold))
            HStack(spacing: 18) {
                Chart(payments) { payment in
                    SectorMark(angle: .value("金額", payment.amount), innerRadius: .ratio(0.55), angularInset: 2)
                        .foregroundStyle(colors[payment.colorIndex % colors.count])
                }
                .chartLegend(.hidden)
                .frame(width: 150, height: 150)

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(payments) { payment in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(colors[payment.colorIndex % colors.count])
                                .frame(width: 10, height: 10)
                            Text(payment.label)
                                .font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("$\(payment.amount)")
                                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .posCard()
    }
}

private struct ReportOrdersTable: View {
    let orders: [POSOrder]
    let select: (POSOrder) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                header("訂單號", width: 112)
                header("時間", width: 72)
                header("桌號", width: 76)
                header("金額", width: 76)
                header("付款方式")
                header("操作", width: 68)
            }
            .padding(.horizontal, 10)
            .frame(height: 48)
            .background(POSColor.primaryStrong)

            if orders.isEmpty {
                EmptyStateView(symbol: "chart.bar.xaxis", message: "此期間沒有訂單資料")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(orders) { order in
                            HStack {
                                cell(order.number, width: 112)
                                cell(order.createdAt.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)), width: 72)
                                cell(order.table, width: 76)
                                cell("$\(order.total)", width: 76)
                                cell(order.paymentMethod)
                                Button("詳情") { select(order) }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                                    .frame(width: 58, height: 32)
                                    .background(POSColor.selectedOrange)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .padding(.horizontal, 10)
                            .frame(minHeight: 54)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(POSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func header(_ text: String, width: CGFloat? = nil) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
    }

    private func cell(_ text: String, width: CGFloat? = nil) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(POSColor.textPrimary)
            .lineLimit(2)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .frame(width: width, alignment: .leading)
    }
}

private struct OrderDetailPanel: View {
    @EnvironmentObject private var store: POSStore
    let order: POSOrder
    let back: () -> Void
    @State private var showCancel = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("返回訂單", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(POSColor.primaryStrong)
                Spacer()
                Text("訂單詳情").font(.system(size: 18, weight: .bold))
                Spacer()
            }
            .padding(14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detail("訂單編號", order.number)
                    detail("時間", order.createdAt.formatted(date: .numeric, time: .shortened))
                    detail("桌號／取餐", order.table)
                    detail("支付方式", order.paymentMethod)
                    detail("狀態", order.status.rawValue)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("商品明細").font(.headline)
                        ForEach(order.lines) { line in
                            HStack {
                                Text(line.name)
                                Spacer()
                                Text("×\(line.quantity)  $\(line.subtotal)")
                            }
                            ForEach(line.modifiers, id: \.self) { modifier in
                                Text("+\(modifier)").font(.caption).foregroundStyle(POSColor.textSecondary)
                            }
                            if let note = line.note, !note.isEmpty { Text(note).font(.caption) }
                            Divider()
                        }
                    }.posCard()
                    detail("合計", "$\(order.total)")
                    if !order.note.isEmpty { detail("備註", order.note) }
                    HStack {
                        Button { Task { await store.reprint(order) } } label: {
                            Label("重新出單", systemImage: "printer.fill")
                        }.buttonStyle(.borderedProminent).tint(POSColor.primaryStrong)
                        if order.status != .cancelled {
                            Button("作廢本機訂單", role: .destructive) { showCancel = true }
                                .buttonStyle(.bordered)
                        }
                    }
                }.padding(18)
            }
        }
        .background(POSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .confirmationDialog("作廢此訂單？", isPresented: $showCancel) {
            Button("確認作廢", role: .destructive) { store.cancelOrder(order.id); back() }
        } message: { Text("僅修改本機訂單狀態與營收統計，不涉及付款退款。") }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(POSColor.textSecondary)
            Text(value).font(.system(size: 15, weight: .semibold))
        }.frame(maxWidth: .infinity, alignment: .leading).posCard()
    }
}
