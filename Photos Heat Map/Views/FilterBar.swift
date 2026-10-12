//
//  FilterBar.swift
//  Photos Heat Map
//

import SwiftUI

struct FilterBar: View {
    @Environment(AppModel.self) private var model
    @State private var showDatePopover = false

    private var filters: Binding<PhotoFilters> {
        Binding(get: { model.filters }, set: { model.updateFilters($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("Type", selection: filters.kind) {
                    ForEach(PhotoFilters.Kind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)

                Toggle(isOn: filters.favoritesOnly) {
                    Image(systemName: model.filters.favoritesOnly ? "heart.fill" : "heart")
                }
                .toggleStyle(.button)
                .help("Favorites only")

                Spacer(minLength: 0)

                if !model.filters.isDefault {
                    Button("Clear") { model.updateFilters(PhotoFilters()) }
                        .controlSize(.small)
                }
            }

            HStack(spacing: 8) {
                Button {
                    showDatePopover.toggle()
                } label: {
                    Label(model.filters.dateRangeDescription, systemImage: "calendar")
                        .lineLimit(1)
                }
                .popover(isPresented: $showDatePopover, arrowEdge: .bottom) {
                    DateRangePopover(filters: filters)
                }

                Spacer(minLength: 0)

                Toggle("Apply to map", isOn: Binding(
                    get: { model.filtersAffectMap },
                    set: { model.setFiltersAffectMap($0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .help("When on, the heat map only shows the filtered photos")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

struct DateRangePopover: View {
    @Binding var filters: PhotoFilters

    private var fromEnabled: Binding<Bool> {
        Binding(
            get: { filters.startDate != nil },
            set: { on in
                let fallback = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
                filters.startDate = on ? (filters.startDate ?? PhotoFilters.startOfDay(fallback)) : nil
            }
        )
    }

    private var toEnabled: Binding<Bool> {
        Binding(
            get: { filters.endDate != nil },
            set: { on in
                filters.endDate = on ? (filters.endDate ?? PhotoFilters.endOfDay(Date())) : nil
            }
        )
    }

    private var fromDate: Binding<Date> {
        Binding(
            get: { filters.startDate ?? Date() },
            set: { filters.startDate = PhotoFilters.startOfDay($0) }
        )
    }

    private var toDate: Binding<Date> {
        Binding(
            get: { filters.endDate ?? Date() },
            set: { filters.endDate = PhotoFilters.endOfDay($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Date Range").font(.headline)

            Grid(alignment: .leading, verticalSpacing: 8) {
                GridRow {
                    Toggle("From", isOn: fromEnabled)
                    DatePicker("", selection: fromDate, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(filters.startDate == nil)
                }
                GridRow {
                    Toggle("To", isOn: toEnabled)
                    DatePicker("", selection: toDate, displayedComponents: .date)
                        .labelsHidden()
                        .disabled(filters.endDate == nil)
                }
            }

            HStack(spacing: 6) {
                presetButton("Past month", months: -1)
                presetButton("Past year", months: -12)
                Button("This year") {
                    let year = Calendar.current.component(.year, from: Date())
                    let start = Calendar.current.date(from: DateComponents(year: year, month: 1, day: 1)) ?? Date()
                    filters.setRange(from: start, to: Date())
                }
                Button("Any time") { filters.setRange(from: nil, to: nil) }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func presetButton(_ title: String, months: Int) -> some View {
        Button(title) {
            let start = Calendar.current.date(byAdding: .month, value: months, to: Date()) ?? Date()
            filters.setRange(from: start, to: Date())
        }
    }
}
