import SwiftUI

struct WatchlistPane: View {
    @Environment(\.container) private var container
    @State private var groups: [WatchlistGroup] = []
    @State private var selectedGroupID: UUID = WatchlistGroup.defaultID
    @State private var items: [WatchItem] = []
    @State private var showAdd: Bool = false
    @State private var editing: WatchItem?
    @State private var deleting: WatchItem?
    @State private var selectedID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(L("settings.watchlist", comment: ""))
                    .font(.title3)

                if groups.count > 1 {
                    Picker("", selection: $selectedGroupID) {
                        ForEach(groups) { g in
                            Text(g.name).tag(g.id)
                        }
                    }
                    .frame(width: 130)
                    .onChange(of: selectedGroupID) { _ in
                        reload()
                    }
                }

                Spacer()
                Button(action: importCSV) {
                    Label(L("action.importCSV", comment: ""), systemImage: "square.and.arrow.down")
                }
                Button(action: exportCSV) {
                    Label(L("action.exportCSV", comment: ""), systemImage: "square.and.arrow.up")
                }
                .disabled(items.isEmpty)
                Button(action: { showAdd = true }) {
                    Label(L("action.add", comment: ""), systemImage: "plus")
                }
            }
            watchlistList
            if items.isEmpty {
                Text(L("watchlist.empty", comment: ""))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
        }
        .padding(20)
        .onAppear {
            reload()
            if SettingsWindowController.pendingAction == .addWatch {
                SettingsWindowController.pendingAction = nil
                showAdd = true
            }
        }
        .sheet(isPresented: $showAdd) {
            WatchEditorSheet(initial: nil, targetGroupID: selectedGroupID, onSaved: {
                showAdd = false
                reload()
                container?.refresher.refreshNow()
            }, onCancel: { showAdd = false })
        }
        .sheet(item: $editing) { existing in
            WatchEditorSheet(initial: existing, targetGroupID: existing.watchlistId, onSaved: {
                editing = nil
                reload()
                container?.refresher.refreshNow()
            }, onCancel: { editing = nil })
        }
        .alert(
            String(format: L("delete.confirm.title", comment: ""), deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(L("action.cancel", comment: ""), role: .cancel) { deleting = nil }
            Button(L("action.delete", comment: ""), role: .destructive) {
                if let w = deleting {
                    try? container?.watchlistRepo.delete(id: w.id)
                    reload()
                    container?.refresher.refreshNow()
                }
                deleting = nil
            }
        } message: {
            Text(L("delete.confirm.body", comment: ""))
        }
    }

    private func reload() {
        groups = (try? container?.watchlistRepo.allGroups()) ?? []
        if !groups.contains(where: { $0.id == selectedGroupID }), let first = groups.first {
            selectedGroupID = first.id
        }
        items = (try? container?.watchlistRepo.all(watchlistId: selectedGroupID)) ?? []
    }

    private var watchlistList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L("col.symbol", comment: "")).frame(width: 80, alignment: .leading)
                Text(L("col.name", comment: "")).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                Text(L("col.market", comment: "")).frame(width: 56, alignment: .leading)
                Spacer().frame(width: 56)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, w in
                        watchRow(w, index: index, isAlternate: index.isMultiple(of: 2))
                    }
                }
            }
            .background(Color(NSColor.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func watchRow(_ w: WatchItem, index: Int, isAlternate: Bool) -> some View {
        let isSelected = selectedID == w.id

        HStack(spacing: 8) {
            Text(w.symbol.market == .us ? w.symbol.code.uppercased() : w.symbol.code)
                .frame(width: 80, alignment: .leading)
            Text(w.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            Text(w.symbol.market.displayName)
                .frame(width: 56, alignment: .leading)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Button { editing = w } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(L("action.edit", comment: ""))
                Button(role: .destructive) {
                    deleting = w
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .frame(width: 56)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected: isSelected, isAlternate: isAlternate))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = w }
        .onTapGesture { selectedID = w.id }
    }

    private func rowBackground(isSelected: Bool, isAlternate: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        return isAlternate ? Color.secondary.opacity(0.05) : Color.clear
    }

    private func exportCSV() {
        let csv = CSVWatchlistIO.exportWatchlist(items)
        CSVWatchlistIO.presentExportPanel(suggestedName: "tickerbar-watchlist.csv", content: csv)
    }

    private func importCSV() {
        CSVWatchlistIO.presentImportPanel { text in
            guard let text = text else { return }
            let imported = CSVWatchlistIO.importWatchlist(text)
            for var w in imported {
                w.watchlistId = selectedGroupID
                try? container?.watchlistRepo.upsert(w)
            }
            reload()
            container?.refresher.refreshNow()
        }
    }
}

private struct WatchEditorSheet: View {
    @Environment(\.container) private var container
    let initial: WatchItem?
    var targetGroupID: UUID = WatchlistGroup.defaultID
    var onSaved: () -> Void
    var onCancel: () -> Void

    @State private var market: Market = .a
    @State private var code: String = ""
    @State private var name: String = ""
    @State private var error: String?

    @StateObject private var searchVM = SymbolSearchViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial == nil ? L("watchlist.addTitle", comment: "") : L("watchlist.editTitle", comment: ""))
                .font(.title3)

            SymbolSearchField(vm: searchVM, onPick: { result in
                market = result.symbol.market
                code = result.symbol.code
                name = result.name
            })

            Form {
                Picker(L("col.market", comment: ""), selection: $market) {
                    ForEach(Market.allCases, id: \.self) { m in
                        Text(m.displayName).tag(m)
                    }
                }
                TextField(L("col.symbol", comment: ""), text: $code)
                    .textFieldStyle(.roundedBorder)
                TextField(L("col.name", comment: ""), text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            if let error = error {
                Text(error).foregroundColor(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button(L("action.cancel", comment: ""), action: onCancel)
                Button(L("action.save", comment: ""), action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            prefill()
            searchVM.bind(container?.symbolSearch ?? DependencyContainer.shared?.symbolSearch)
        }
    }

    private func prefill() {
        guard let w = initial else { return }
        market = w.symbol.market
        code = w.symbol.code
        name = w.name
    }

    private func save() {
        guard !code.isEmpty else { error = L("error.codeRequired", comment: ""); return }
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        let sid = SymbolID(code: trimmed, market: market)
        let item: WatchItem
        if var existing = initial {
            existing.symbol = sid
            existing.name = name.isEmpty ? trimmed : name
            item = existing
        } else {
            item = WatchItem(symbol: sid, name: name.isEmpty ? trimmed : name, watchlistId: targetGroupID)
        }
        do {
            try container?.watchlistRepo.upsert(item)
            onSaved()
        } catch {
            self.error = "\(error)"
        }
    }
}
