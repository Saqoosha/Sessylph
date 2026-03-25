// Sources/Sessylph/ChatUI/PermissionBanner.swift
import SwiftUI

struct PermissionBanner: View {
    let permission: ChatViewModel.PendingPermission
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.yellow)
                Text("Permission Required")
                    .fontWeight(.semibold)
            }
            .font(.callout)

            HStack(spacing: 4) {
                Text(permission.displayName ?? permission.toolName)
                    .fontWeight(.medium)
                if let desc = permission.description {
                    Text("— \(desc)")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .font(.callout)

            // Show tool input preview
            if let input = permission.input {
                Text(input.displaySummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(6)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            HStack {
                Button("Allow") { onAllow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])

                Button("Deny") { onDeny() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()
            }
        }
        .padding(12)
        .background(.yellow.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.yellow.opacity(0.3), lineWidth: 1)
        )
    }
}
