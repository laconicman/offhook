import SwiftUI

/// The single screen of the Phase 0 bring-up app: account fields, the start/register/dial
/// controls, the current call's state, and a live engine-event log.
///
/// `@Bindable` exposes two-way bindings into the injected `@Observable` ``PhoneModel`` for the
/// text fields; everything else is read-only observable state. View → model only (the view never
/// touches the engine). Sections are extracted to keep `body` small (view decomposition).
struct RootView: View {
    @Bindable var model: PhoneModel

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                callSection
                diagnosticsSection
                logSection
            }
            .navigationTitle("Offhook · bring-up")
            .task { await model.autoSmokeIfRequested() }
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section("Account") {
            TextField("Registrar host", text: $model.registrar)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Username", text: $model.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $model.password)

            LabeledContent("Engine", value: model.engineStateText)
            LabeledContent("Registration", value: model.registration)

            HStack {
                Button("Start engine") { Task { await model.startEngine() } }
                    .disabled(model.engineState != .idle)
                Spacer()
                Button("Save & register") { Task { await model.register() } }
                    .disabled(!model.canRegister)
            }
        }

        if !model.accounts.isEmpty {
            Section("Saved accounts") {
                ForEach(model.accounts) { saved in
                    VStack(alignment: .leading) {
                        Text(saved.aor).font(.callout.monospaced())
                        Text(model.accountStates[saved.id] ?? "saved")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            Task { await model.removeAccount(saved) }
                        }
                    }
                    .contextMenu {
                        Button("Register") { Task { await model.register(saved) } }
                    }
                }
            }
        }
    }

    @ViewBuilder private var callSection: some View {
        Section("Calls") {
            TextField("Dial (sip:…)", text: $model.dialTarget)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            ForEach(model.calls) { call in
                LabeledContent(String(call.id.uuidString.prefix(8)), value: call.state)
                HStack {
                    Button("Hang up", role: .destructive) { Task { await model.hangUp(call.id) } }
                    Spacer()
                    Button(call.isOnHold ? "Resume" : "Hold") {
                        Task { await model.setHeld(call.id, onHold: !call.isOnHold) }
                    }
                }
                .font(.callout)
            }

            Button("Dial") { Task { await model.dial() } }
                .disabled(!model.canDial)
        }
    }

    @ViewBuilder private var diagnosticsSection: some View {
        Section("Diagnostics") {
            NavigationLink("Events & conference slots") {
                DiagnosticsView(model: model)
            }
        }
    }

    @ViewBuilder private var logSection: some View {
        Section("Event log") {
            if model.log.isEmpty {
                Text("No events yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.log.reversed()) { entry in   // newest first; stable UUID identity
                    Text(entry.text)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

#Preview {
    RootView(model: PhoneModel())
}
