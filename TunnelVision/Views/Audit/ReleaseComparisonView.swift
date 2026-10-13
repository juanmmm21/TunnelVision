import Shared
import SwiftUI

/// Dos sesiones de auditoría de la misma app, una contra otra: qué dominios contactó una versión y
/// la otra no, y dónde cambió la versión de TLS.
///
/// No decide nada: lo que se enseña, en qué orden y con qué palabras es de
/// `ReleaseComparisonPresentation`. Lo suyo es el orden de la pantalla, que es el de la pregunta
/// que la abre — *¿qué hay de nuevo en esta versión?*: primero las cifras, luego lo nuevo, luego lo
/// que cambió, y al final lo que desapareció, que es lo que menos se viene a buscar.
struct ReleaseComparisonView: View {

    let viewModel: AuditViewModel
    let sessionID: Int64
    let otherID: Int64

    var body: some View {
        Group {
            switch viewModel.comparisonState(of: sessionID, with: otherID) {
            case .loading:
                ScrollView {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                }
                .screenCanvas()
            case .failed(let notice):
                List {
                    Section {
                        AuditNoticeBanner(notice: notice) {}
                    }
                    .listRowBackground(Color(.surface))
                }
                .listStyle(.insetGrouped)
                .listCanvas()
            case .loaded(let display):
                list(display)
            }
        }
        .navigationTitle(ReleaseComparisonPresentation.screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        // Las filas se deslizan bajo la barra: opaca, como en las otras pantallas empujadas
        // (`docs/ux/design-system.md`).
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarBackground(Color(.canvas), for: .navigationBar)
        .refreshable { await viewModel.loadComparison(of: sessionID, with: otherID) }
        .task { await viewModel.loadComparison(of: sessionID, with: otherID) }
    }

    private func list(_ display: ReleaseComparisonDisplay) -> some View {
        List {
            Section {
                ValueRow(label: ReleaseComparisonPresentation.laterLabel, value: display.laterTitle)
                ValueRow(label: ReleaseComparisonPresentation.earlierLabel, value: display.earlierTitle)
                ForEach(display.counts) { fact in
                    AuditFactRow(fact: fact)
                }
            } footer: {
                AuditSectionFooter(display.direction)
            }
            .listRowBackground(Color(.surface))

            Section {
                if display.newDomains.isEmpty {
                    Text(ReleaseComparisonPresentation.nothingNew)
                        .font(.cardBody)
                        .foregroundStyle(Color(.neutral))
                } else {
                    ForEach(display.newDomains) { row in
                        ReleaseComparisonRowView(row: row)
                    }
                }
            } header: {
                SectionHeader(ReleaseComparisonPresentation.newDomainsTitle)
            } footer: {
                AuditSectionFooter(ReleaseComparisonPresentation.newDomainsFooter)
            }
            .listRowBackground(Color(.surface))

            if !display.tlsChanges.isEmpty {
                Section {
                    ForEach(display.tlsChanges) { row in
                        ReleaseComparisonRowView(row: row)
                    }
                } header: {
                    SectionHeader(ReleaseComparisonPresentation.tlsChangesTitle)
                }
                .listRowBackground(Color(.surface))
            }

            if !display.goneDomains.isEmpty {
                Section {
                    ForEach(display.goneDomains) { row in
                        ReleaseComparisonRowView(row: row)
                    }
                } header: {
                    SectionHeader(ReleaseComparisonPresentation.goneDomainsTitle)
                }
                .listRowBackground(Color(.surface))
            }

            if let caveat = display.caveat {
                Section {
                    Text(caveat)
                        .font(.supporting)
                        .foregroundStyle(Color(.neutral))
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.insetGrouped)
        .listCanvas()
    }
}

/// Un dominio de la comparación: el nombre en el papel `literal` —se lee carácter a carácter, como
/// un patrón de la allowlist— y debajo lo que hay que decir de él. El que pide atención lleva su
/// símbolo **además** del color, que solo no llega a quien no lo distingue.
private struct ReleaseComparisonRowView: View {

    let row: ReleaseComparisonRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(row.host)
                .font(.literal)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                if row.role == .warning {
                    Image(systemName: "exclamationmark.circle")
                        .accessibilityHidden(true)
                }
                Text(row.detail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.supporting)
            .foregroundStyle(row.role == .warning ? StatusRole.warning.color : Color(.neutral))
        }
        .padding(.vertical, Spacing.tight)
        .accessibilityElement(children: .combine)
    }
}
