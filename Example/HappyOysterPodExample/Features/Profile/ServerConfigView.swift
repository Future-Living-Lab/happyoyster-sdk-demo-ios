import SwiftUI

/// Server configuration sheet: enter the local server HOST / optional PORT / scheme and save to AppEnvironment.
struct ServerConfigView: View {
    @EnvironmentObject private var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var portText: String = ""
    @State private var scheme: String = "http"

    private let schemes = ["http", "https"]

    private enum Field: Hashable { case host, port }
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text("Scheme")
                        Spacer()
                        Picker("Scheme", selection: $scheme) {
                            ForEach(schemes, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 140)
                    }

                    HStack {
                        Text("HOST")
                        Spacer()
                        TextField("127.0.0.1", text: $host)
                            .focused($focusedField, equals: .host)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: 200)
                    }

                    HStack {
                        Text("PORT")
                        Spacer()
                        TextField("Optional", text: $portText)
                            .focused($focusedField, equals: .port)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 100)
                    }
                } header: {
                    Text("Local Server")
                } footer: {
                    Text("PORT is optional; when empty, the protocol's default port is used.\nCurrent address: \(env.localServerAddress)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Server Configuration")
            .navigationBarTitleDisplayMode(.inline)
            // Keyboard dismissal goes through the keyboard toolbar "Done" button only; no container-level
            // gesture competing with TextField/Picker for hit-testing.
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .onAppear { loadCurrentValues() }
        }
    }

    private var isValid: Bool {
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            (trimmedPort.isEmpty || Int(trimmedPort).map { (1...65535).contains($0) } == true)
    }

    private func loadCurrentValues() {
        host     = env.host
        portText = env.port.map(String.init) ?? ""
        scheme   = env.scheme
    }

    private func save() {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else { return }

        let port: Int?
        if trimmedPort.isEmpty {
            port = nil
        } else {
            guard let value = Int(trimmedPort), (1...65535).contains(value) else { return }
            port = value
        }

        env.host   = trimmedHost
        env.port   = port
        env.scheme = scheme
        dismiss()
    }
}
