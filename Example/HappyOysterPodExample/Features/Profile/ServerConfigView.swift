import SwiftUI

/// 服务器配置弹窗：输入本地服务器 HOST / 可选 PORT / scheme，保存到 AppEnvironment。
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
                        TextField("可不填", text: $portText)
                            .focused($focusedField, equals: .port)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 100)
                    }
                } header: {
                    Text("本地服务器")
                } footer: {
                    Text("PORT 可不填，留空时使用协议默认端口。\n当前地址：\(env.localServerAddress)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("服务器配置")
            .navigationBarTitleDisplayMode(.inline)
            // 收起键盘统一走键盘工具栏「完成」按钮，不用容器级手势跟 TextField/Picker
            // 抢占命中测试。
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }
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
